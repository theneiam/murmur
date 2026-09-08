import Foundation
import WhisperKit
import os

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        default: return false
        }
    }
}

/// Owns model files on disk and the single warm `TranscriptionEngine`.
///
/// Files live in `~/Library/Application Support/Murmur/Models`, laid out the
/// way WhisperKit's Hub client expects:
/// `Models/models/argmaxinc/whisperkit-coreml/<variant>/…`.
@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var statuses: [WhisperModel: ModelStatus] = [:]
    /// The model currently loaded (or being loaded) in the engine.
    @Published private(set) var activeModel: WhisperModel?

    let engine: any TranscriptionEngine
    let rootDirectory: URL

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "models")
    private var loadTask: Task<Void, Never>?
    /// Bumped on every `activate`; a queued load whose generation is stale
    /// (the user picked yet another model meanwhile) is skipped.
    private var loadGeneration = 0
    /// The model of the most recent `activate` call, so a skipped stale
    /// request can tell whether its model is still wanted.
    private var latestRequested: WhisperModel?
    private var downloadTasks: [WhisperModel: Task<Void, Never>] = [:]

    init(engine: any TranscriptionEngine = WhisperKitEngine(), rootDirectory: URL? = nil) {
        self.engine = engine
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.rootDirectory = rootDirectory
            ?? support.appendingPathComponent("Murmur", isDirectory: true).appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
        refreshStatuses()
    }

    // MARK: Paths

    func folder(for model: WhisperModel) -> URL {
        rootDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.repo, isDirectory: true)
            .appendingPathComponent(model.rawValue, isDirectory: true)
    }

    var tokenizerDirectory: URL {
        rootDirectory.appendingPathComponent("tokenizers", isDirectory: true)
    }

    func isDownloaded(_ model: WhisperModel) -> Bool {
        Self.isCompleteBundle(at: folder(for: model))
    }

    /// The compiled CoreML models every WhisperKit bundle ships with. The Hub
    /// client downloads them one file at a time, so an interrupted download
    /// can leave the encoder in place with no decoder yet.
    static let requiredModelDirectories = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
    static let requiredFiles = ["config.json"]

    /// `true` when `folder` holds a loadable bundle: each compiled model
    /// directory exists and contains its `coremldata.bin`, and the config is
    /// present. Pure so it can be tested against a temporary directory.
    nonisolated static func isCompleteBundle(at folder: URL) -> Bool {
        let fm = FileManager.default
        for name in requiredModelDirectories {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
            guard fm.fileExists(atPath: dir.appendingPathComponent("coremldata.bin").path) else { return false }
        }
        for name in requiredFiles {
            guard fm.fileExists(atPath: folder.appendingPathComponent(name).path) else { return false }
        }
        return true
    }

    func status(of model: WhisperModel) -> ModelStatus {
        statuses[model] ?? .notDownloaded
    }

    var isReady: Bool {
        guard let activeModel else { return false }
        return status(of: activeModel) == .ready
    }

    /// `true` when `model` can be used for the next dictation: either warm,
    /// or on disk and loadable on demand (recording does not need the model;
    /// only transcription does).
    func isAvailable(_ model: WhisperModel) -> Bool {
        switch status(of: model) {
        case .ready, .loading, .downloaded: return true
        case .notDownloaded, .downloading, .failed: return false
        }
    }

    func refreshStatuses() {
        for model in WhisperModel.allCases {
            switch statuses[model] {
            case .downloading, .loading, .ready:
                continue
            default:
                statuses[model] = isDownloaded(model) ? .downloaded : .notDownloaded
            }
        }
    }

    // MARK: Download

    // MARK: Free space

    /// Headroom on top of the bundle size: CoreML writes a specialised copy
    /// of the model into its cache on first load.
    static let freeSpaceMargin: Int64 = 500 * 1_000_000

    static func requiredFreeBytes(for model: WhisperModel) -> Int64 {
        Int64(model.approximateSizeMB) * 1_000_000 * 12 / 10 + freeSpaceMargin
    }

    static func hasEnoughFreeSpace(for model: WhisperModel, availableBytes: Int64) -> Bool {
        availableBytes >= requiredFreeBytes(for: model)
    }

    /// Bytes the system would let an important download use on the models volume.
    func availableBytes() -> Int64? {
        let values = try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Download

    /// Downloads the model bundle (idempotent: already-present files are
    /// skipped by the Hub client, so a cancelled or failed download resumes
    /// where it stopped). This is the only network access Murmur ever
    /// performs, and it only happens on explicit user action.
    func download(_ model: WhisperModel, thenActivate: Bool = false) {
        guard !status(of: model).isBusy else { return }
        if let available = availableBytes(), !Self.hasEnoughFreeSpace(for: model, availableBytes: available) {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let needed = formatter.string(fromByteCount: Self.requiredFreeBytes(for: model))
            let have = formatter.string(fromByteCount: available)
            statuses[model] = .failed("Not enough free disk space: needs about \(needed), \(have) available.")
            return
        }
        statuses[model] = .downloading(progress: 0)
        downloadTasks[model] = Task { [weak self] in
            await self?.performDownload(model, thenActivate: thenActivate)
        }
    }

    /// Stops an in-progress download. Files already fetched stay on disk so a
    /// later Download continues from there.
    func cancelDownload(_ model: WhisperModel) {
        downloadTasks[model]?.cancel()
    }

    private func performDownload(_ model: WhisperModel, thenActivate: Bool) async {
        defer { downloadTasks[model] = nil }
        // The Hub client reports progress very frequently; coalesce to whole
        // percent so we don't spawn a main-actor hop per callback.
        let lastPercent = OSAllocatedUnfairLock(initialState: -1)
        do {
            _ = try await WhisperKit.download(
                variant: model.rawValue,
                downloadBase: rootDirectory,
                useBackgroundSession: false,
                from: model.repo,
                progressCallback: { @Sendable [weak self] progress in
                    let fraction = progress.fractionCompleted
                    let percent = Int(fraction * 100)
                    let changed = lastPercent.withLock { last -> Bool in
                        guard percent != last else { return false }
                        last = percent
                        return true
                    }
                    guard changed else { return }
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.status(of: model) else { return }
                        self.statuses[model] = .downloading(progress: fraction)
                    }
                }
            )
            if isDownloaded(model) {
                statuses[model] = .downloaded
                log.info("Downloaded \(model.rawValue, privacy: .public)")
                if thenActivate { activate(model) }
            } else if Task.isCancelled {
                statuses[model] = .notDownloaded
            } else {
                statuses[model] = .failed("Download finished but the model bundle is incomplete.")
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                log.info("Download of \(model.rawValue, privacy: .public) cancelled")
                statuses[model] = isDownloaded(model) ? .downloaded : .notDownloaded
            } else {
                log.error("Download of \(model.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                statuses[model] = .failed(error.localizedDescription)
            }
        }
    }

    func delete(_ model: WhisperModel) async {
        // Join the load queue so we never pull the files out from under a
        // load that is still in flight (and drop any queued activation).
        loadGeneration += 1
        await loadTask?.value
        if activeModel == model {
            await engine.unload()
            activeModel = nil
        }
        try? FileManager.default.removeItem(at: folder(for: model))
        statuses[model] = .notDownloaded
    }

    // MARK: Activation

    /// Makes `model` the engine's warm model. Never downloads on its own —
    /// if the files are missing the user is shown a Download button instead.
    ///
    /// Loads are serialised: a CoreML load cannot be interrupted once started,
    /// and the engine actor is re-entrant at its `await`, so two overlapping
    /// `load` calls would build two pipelines and leave the engine holding a
    /// different model than `activeModel` reports. Each request waits for the
    /// one before it, and requests that were superseded while waiting are
    /// dropped so A → B → C only ever loads A then C.
    func activate(_ model: WhisperModel) {
        guard isDownloaded(model) else {
            statuses[model] = .notDownloaded
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        latestRequested = model
        // Reflect the request immediately so the UI shows a spinner rather
        // than a stale "Use" button until the queued task gets to run.
        if status(of: model) != .ready { statuses[model] = .loading }
        let previous = loadTask
        loadTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard generation == self.loadGeneration else {
                // Superseded before it started. Unless a newer request wants
                // the same model (or it is the one actually loading), put its
                // status back so nothing is left showing "Loading" forever.
                if self.latestRequested != model, self.activeModel != model, self.status(of: model) == .loading {
                    self.statuses[model] = .downloaded
                }
                return
            }
            await self.performActivate(model)
        }
    }

    /// Waits for whatever activation is in flight (including ones queued
    /// behind it) and reports whether the engine ended up ready.
    func awaitActivation() async -> Bool {
        while true {
            let generation = loadGeneration
            await loadTask?.value
            if generation == loadGeneration { break }
        }
        return isReady
    }

    /// Drops the warm model to free memory (≈0.5–1.5 GB). Files stay on
    /// disk; `activate` brings it back. No-op while a load is queued.
    func unloadForIdle() async {
        guard let active = activeModel, status(of: active) == .ready else { return }
        loadGeneration += 1
        await loadTask?.value
        guard activeModel == active, status(of: active) == .ready else { return }
        await engine.unload()
        statuses[active] = .downloaded
        activeModel = nil
        log.info("Unloaded \(active.rawValue, privacy: .public) after idle timeout")
    }

    private func performActivate(_ model: WhisperModel) async {
        if activeModel == model, status(of: model) == .ready { return }

        if let previous = activeModel, previous != model, status(of: previous) == .ready {
            statuses[previous] = .downloaded
        }
        activeModel = model
        statuses[model] = .loading
        do {
            try await engine.load(model: model, folder: folder(for: model), tokenizerFolder: tokenizerDirectory)
            // Always record the truth: the engine now holds `model`. If a newer
            // request is queued it runs next and moves this one back to
            // `.downloaded` itself.
            statuses[model] = .ready
        } catch is CancellationError {
            statuses[model] = .downloaded
            if activeModel == model { activeModel = nil }
        } catch {
            log.error("Loading \(model.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            statuses[model] = .failed(error.localizedDescription)
            if activeModel == model { activeModel = nil }
        }
    }
}
