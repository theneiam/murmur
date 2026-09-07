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

    init(engine: any TranscriptionEngine = WhisperKitEngine()) {
        self.engine = engine
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootDirectory = support.appendingPathComponent("Murmur", isDirectory: true).appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
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
        let folder = folder(for: model)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        // A complete WhisperKit bundle always contains the compiled audio encoder.
        return contents.contains { $0.hasPrefix("AudioEncoder") && $0.hasSuffix(".mlmodelc") }
    }

    func status(of model: WhisperModel) -> ModelStatus {
        statuses[model] ?? .notDownloaded
    }

    var isReady: Bool {
        guard let activeModel else { return false }
        return status(of: activeModel) == .ready
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

    /// Downloads the model bundle (idempotent: already-present files are
    /// skipped by the Hub client). This is the only network access Murmur
    /// ever performs, and it only happens on explicit user action.
    func download(_ model: WhisperModel, thenActivate: Bool = false) async {
        guard !status(of: model).isBusy else { return }
        statuses[model] = .downloading(progress: 0)
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
            statuses[model] = isDownloaded(model) ? .downloaded : .failed("Download finished but the model bundle is incomplete.")
            log.info("Downloaded \(model.rawValue, privacy: .public)")
            if thenActivate, isDownloaded(model) { activate(model) }
        } catch {
            log.error("Download of \(model.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            statuses[model] = .failed(error.localizedDescription)
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
        let previous = loadTask
        loadTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.loadGeneration else { return }
            await self.performActivate(model)
        }
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
