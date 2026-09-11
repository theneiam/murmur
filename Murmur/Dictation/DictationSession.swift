import Foundation
import os

/// The push-to-talk pipeline: hold → record → transcribe → post-process →
/// insert. Owns the phase machine and nothing else; audio, models, insertion
/// and presentation arrive through the seams in `DictationSeams.swift`, so
/// the whole flow is testable with fakes.
///
/// Interface: `press()`, `release()`, `cancel()` (delivered on main by the
/// hotkey layer), published state for the UI, and `onEvent` for one-off
/// outcomes. `insertSample()` reuses the insertion path for the Settings
/// "Test insertion" button.
@MainActor
final class DictationSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Key down; the audio engine is starting.
        case starting
        case recording
        case transcribing
        case inserting
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastInsertionMethod: InsertionMethod?

    var onEvent: ((DictationEvent) -> Void)?

    private let recorder: any AudioCapturing
    private let models: any ModelProviding
    private let inserter: any TextInserting
    private let presenter: any DictationPresenting
    private let config: () -> DictationConfig
    private let transcriptionTimeout: Duration
    private let minimumUtterance: TimeInterval
    private let sampleDelay: Duration
    private let log = Logger.murmur("dictation")

    /// Configuration captured at `press()`; valid until the phase returns to idle.
    private var current: DictationConfig?

    init(
        recorder: any AudioCapturing,
        models: any ModelProviding,
        inserter: any TextInserting,
        presenter: any DictationPresenting,
        config: @escaping () -> DictationConfig,
        transcriptionTimeout: Duration = .seconds(90),
        minimumUtterance: TimeInterval = 0.3,
        sampleDelay: Duration = .seconds(3)
    ) {
        self.recorder = recorder
        self.models = models
        self.inserter = inserter
        self.presenter = presenter
        self.config = config
        self.transcriptionTimeout = transcriptionTimeout
        self.minimumUtterance = minimumUtterance
        self.sampleDelay = sampleDelay

        recorder.onLevel = { [weak self] level in self?.presenter.push(level: level) }
        recorder.onAutoStop = { [weak self] recording in
            self?.log.info("Recording hit the maximum duration; transcribing")
            self?.finish(recording)
        }
    }

    // MARK: Interface

    func press() {
        guard phase == .idle else { return }
        phase = .starting
        beginRecording()
    }

    func release() {
        switch phase {
        case .starting:
            // Released before the engine came up: a tap, not an utterance.
            phase = .idle
        case .recording:
            finish(recorder.stop())
        default:
            break
        }
    }

    func cancel() {
        switch phase {
        case .starting:
            phase = .idle
        case .recording:
            recorder.stop()
            phase = .idle
            presenter.hide()
        default:
            break
        }
    }

    /// Inserts a sample sentence into whatever app is frontmost after a short
    /// countdown and reports which path delivered it.
    func insertSample() {
        guard phase == .idle else { return }
        let strategy = config().insertionStrategy
        presenter.showMessage("Click into the app you want to test — inserting a sample in 3 s…", for: MessageDuration.error)
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: sampleDelay)
            guard phase == .idle else { return }
            let sample = "Murmur insertion test at \(Date().formatted(date: .omitted, time: .standard)). "
            do {
                let method = try await inserter.insert(sample, strategy: strategy)
                lastInsertionMethod = method
                log.info("Insertion test: \(method.rawValue, privacy: .public)")
                presenter.showMessage("Inserted via \(method.displayName). Check that the text landed exactly once.", for: MessageDuration.guidance)
            } catch {
                presenter.showMessage(error.localizedDescription, for: MessageDuration.guidance)
            }
        }
    }

    // MARK: Pipeline

    private func beginRecording() {
        guard phase == .starting else { return }
        let cfg = config()
        current = cfg

        guard cfg.microphoneAuthorized else {
            phase = .idle
            presenter.showMessage("Microphone access is required", for: MessageDuration.short)
            return
        }
        // Recording does not need the model. If it is on disk but cold
        // (first use, or dropped after the idle timeout) start loading now so
        // it warms up while the user speaks; `finish` waits for it.
        switch models.availability(of: cfg.model) {
        case .warm, .loading:
            break
        case .cold:
            models.activate(cfg.model)
        case let .blocked(reason):
            phase = .idle
            presenter.showMessage(reason, for: MessageDuration.actionable)
            return
        }

        do {
            try recorder.start(inputDeviceUID: cfg.inputDeviceUID, maxDuration: cfg.maxRecordingSeconds)
            phase = .recording
            presenter.showRecording()
            if cfg.playSounds { presenter.playCue(.start) }
        } catch {
            phase = .idle
            lastError = error.localizedDescription
            presenter.showMessage(error.localizedDescription, for: MessageDuration.short)
        }
    }

    private func finish(_ recording: Recording) {
        guard phase == .recording, let cfg = current else { return }
        if cfg.playSounds { presenter.playCue(.stop) }

        guard recording.duration >= minimumUtterance else {
            phase = .idle
            if recording.isSilentCaptureFailure(minimumUtterance: minimumUtterance) {
                let message = recording.silentCaptureFailureMessage
                lastError = message
                presenter.showMessage(message, for: MessageDuration.guidance)
                onEvent?(.failed(message))
            } else {
                presenter.hide()
            }
            return
        }

        phase = .transcribing
        let warm = models.availability(of: cfg.model) == .warm
        presenter.showWorking(warm ? "Transcribing…" : "Loading model…")

        Task { [weak self] in
            guard let self else { return }
            do {
                if !warm {
                    guard await models.awaitActivation(of: cfg.model) else {
                        throw TranscriptionError.modelNotLoaded
                    }
                    presenter.showWorking("Transcribing…")
                }
                let transcript = try await transcribe(recording.samples, language: cfg.language)
                let text = TextPostProcessor.process(transcript.text, options: cfg.postProcessing)
                lastTranscript = text.trimmingCharacters(in: .whitespaces)

                guard !text.isEmpty else {
                    presenter.showMessage("Didn't catch that", for: MessageDuration.glance)
                    phase = .idle
                    onEvent?(.noSpeech)
                    return
                }

                phase = .inserting
                presenter.hide()
                let method = try await inserter.insert(text, strategy: cfg.insertionStrategy)
                lastInsertionMethod = method
                lastError = nil
                log.info("Inserted \(text.count, privacy: .public) characters via \(method.rawValue, privacy: .public) (\(transcript.processingTime, privacy: .public) s)")
                phase = .idle
                onEvent?(.inserted(DictationOutcome(
                    timestamp: Date(),
                    characters: text.count,
                    words: DictationOutcome.wordCount(of: text),
                    recordedSeconds: recording.duration,
                    transcriptionSeconds: transcript.processingTime,
                    method: method,
                    model: cfg.model
                )))
                if recording.deviceIsBluetooth { onEvent?(.usedBluetoothInput) }
            } catch {
                lastError = error.localizedDescription
                presenter.showMessage(error.localizedDescription, for: MessageDuration.error)
                log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                phase = .idle
                onEvent?(.failed(error.localizedDescription))
            }
        }
    }

    /// A stalled CoreML call must never leave the app stuck in
    /// `.transcribing` with no way back to idle.
    private func transcribe(_ samples: [Float], language: TranscriptionLanguage) async throws -> Transcript {
        let engine = models.engine
        let timeout = transcriptionTimeout
        return try await withThrowingTaskGroup(of: Transcript.self) { group in
            group.addTask { try await engine.transcribe(samples: samples, language: language) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TranscriptionError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
