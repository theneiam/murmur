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
    @Published private(set) var lastRawTranscript: String?
    @Published private(set) var lastDeliveryStatus: DeliveryStatus?
    private var currentDestination: InsertionDestination?
    @Published private(set) var lastTiming: DictationTiming?
    private var hasModelLease = false
    private var sampleTask: Task<Void, Never>?
    @Published private(set) var lastError: String?
    @Published private(set) var lastInsertionMethod: InsertionMethod?
    /// Language the model reported for the last dictation, when auto-detecting.
    @Published private(set) var lastDetectedLanguage: String?

    var onEvent: ((DictationEvent) -> Void)?

    private let recorder: any AudioCapturing
    private let models: any ModelProviding
    private let inserter: any TextInserting
    private let presenter: any DictationPresenting
    private let config: () -> DictationConfig
    private let destinationConfig: ((String?) -> DictationConfig)?
    private let transcriptionTimeout: Duration
    private let minimumUtterance: TimeInterval
    private let sampleDelay: Duration
    private let now: () -> TimeInterval
    private let log = Logger.murmur("dictation")

    /// Configuration captured at `press()`; valid until the phase returns to idle.
    private var current: DictationConfig?
    private var processingTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    @Published private(set) var hasPendingWork = false

    init(
        recorder: any AudioCapturing,
        models: any ModelProviding,
        inserter: any TextInserting,
        presenter: any DictationPresenting,
        config: @escaping () -> DictationConfig,
        destinationConfig: ((String?) -> DictationConfig)? = nil,
        transcriptionTimeout: Duration = .seconds(90),
        minimumUtterance: TimeInterval = 0.3,
        sampleDelay: Duration = .seconds(3),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.recorder = recorder
        self.models = models
        self.inserter = inserter
        self.presenter = presenter
        self.config = config
        self.destinationConfig = destinationConfig
        self.transcriptionTimeout = transcriptionTimeout
        self.minimumUtterance = minimumUtterance
        self.sampleDelay = sampleDelay
        self.now = now

        recorder.onLevel = { [weak self] level in self?.presenter.push(level: level) }
        recorder.onAutoStop = { [weak self] recording in
            self?.log.info("Recording hit the maximum duration; transcribing")
            self?.finish(recording)
        }
    }

    // MARK: Interface

    func press(verbatim: Bool = false) {
        guard phase == .idle else { return }
        guard !hasPendingWork else {
            presenter.showMessage("The previous transcription is still stopping. Try again shortly.", for: MessageDuration.short)
            return
        }
        sampleTask?.cancel()
        phase = .starting
        beginRecording(verbatim: verbatim)
    }

    func release() {
        switch phase {
        case .starting:
            // Released before the engine came up: a tap, not an utterance.
            releaseModel()
            phase = .idle
        case .recording:
            finish(recorder.stop())
        default:
            break
        }
    }

    func cancel() {
        sampleTask?.cancel()
        switch phase {
        case .starting:
            releaseModel()
            phase = .idle
        case .recording:
            recorder.stop()
            releaseModel()
            phase = .idle
            presenter.hide()
        case .transcribing, .inserting:
            processingTask?.cancel()
            timeoutTask?.cancel()
            phase = .idle
            presenter.hide()
        default:
            break
        }
    }

    /// Inserts a sample sentence into whatever app is frontmost after a short
    /// countdown and reports which path delivered it.
    func insertSample() {
        guard phase == .idle, !hasPendingWork else { return }
        sampleTask?.cancel()
        presenter.showMessage("Click into the app you want to test — inserting a sample in 3 s…", for: MessageDuration.error)
        sampleTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: sampleDelay) } catch { return }
            guard phase == .idle, !hasPendingWork else { return }
            phase = .inserting
            defer { phase = .idle
                sampleTask = nil
            }
            let sample = "Murmur insertion test at \(Date().formatted(date: .omitted, time: .standard)). "
            do {
                var destination = inserter.captureDestination()
                let cfg = configuration(for: destination)
                destination?.newlinePreference = cfg.newlinePreference
                let result = try await inserter.insert(sample, strategy: cfg.insertionStrategy, destination: destination)
                let method = result.method
                lastDeliveryStatus = result.delivery
                lastInsertionMethod = method
                log.info("Insertion test: \(method.rawValue, privacy: .public)")
                presenter.showMessage("\(result.summary). Check that the text landed exactly once.", for: MessageDuration.guidance)
            } catch {
                presenter.showMessage(error.localizedDescription, for: MessageDuration.guidance)
            }
        }
    }

    // MARK: Pipeline

    private func beginRecording(verbatim: Bool) {
        guard phase == .starting else { return }
        currentDestination = inserter.captureDestination()
        var cfg = configuration(for: currentDestination)
        currentDestination?.newlinePreference = cfg.newlinePreference
        if verbatim { cfg.postProcessing.verbatim = true }
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

        guard models.beginUse(of: cfg.model) else {
            phase = .idle
            presenter.showMessage("The speech model is busy. Try again shortly.", for: MessageDuration.short)
            return
        }
        hasModelLease = true
        do {
            try recorder.start(inputDeviceUID: cfg.inputDeviceUID, maxDuration: cfg.maxRecordingSeconds)
            phase = .recording
            presenter.showRecording()
            if cfg.playSounds { presenter.playCue(.start) }
        } catch {
            releaseModel()
            phase = .idle
            lastError = error.localizedDescription
            presenter.showMessage(error.localizedDescription, for: MessageDuration.short)
        }
    }

    private func finish(_ recording: Recording) {
        guard phase == .recording, let cfg = current else { return }
        if cfg.playSounds { presenter.playCue(.stop) }
        defer { if phase != .transcribing { releaseModel() } }
        if let error = recording.captureError {
            phase = .idle
            lastError = error
            presenter.showMessage(error, for: MessageDuration.error)
            onEvent?(.failed(error))
            return
        }

        guard recording.duration >= minimumUtterance else {
            phase = .idle
            if recording.hasNoAudibleSignal {
                let message = recording.silentInputMessage
                lastError = message
                presenter.showMessage(message, for: MessageDuration.guidance)
                onEvent?(.failed(message))
            } else if recording.isSilentCaptureFailure(minimumUtterance: minimumUtterance) {
                let message = recording.silentCaptureFailureMessage
                lastError = message
                presenter.showMessage(message, for: MessageDuration.guidance)
                onEvent?(.failed(message))
            } else {
                presenter.hide()
            }
            return
        }

        guard !recording.hasNoAudibleSignal else {
            phase = .idle
            let message = recording.silentInputMessage
            lastError = message
            presenter.showMessage(message, for: MessageDuration.guidance)
            onEvent?(.failed(message))
            return
        }

        let releasedAt = now()
        phase = .transcribing
        let warm = models.availability(of: cfg.model) == .warm
        presenter.showWorking(warm ? "Transcribing…" : "Loading model…")

        hasPendingWork = true
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: transcriptionTimeout) } catch { return }
            guard phase == .transcribing else { return }
            processingTask?.cancel()
            let message = TranscriptionError.timedOut.localizedDescription
            lastError = message
            phase = .idle
            presenter.showMessage(message, for: MessageDuration.error)
            onEvent?(.failed(message))
        }
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { timeoutTask?.cancel()
                timeoutTask = nil
                releaseModel()
                hasPendingWork = false
                processingTask = nil
            }
            do {
                try Task.checkCancellation()
                guard await models.awaitActivation(of: cfg.model) else { throw TranscriptionError.modelNotLoaded }
                try Task.checkCancellation()
                if !warm { presenter.showWorking("Transcribing…") }
                let modelReadyAt = now()
                let transcript = try await models.engine.transcribe(samples: recording.samples, language: cfg.language)
                try Task.checkCancellation()
                let transcribedAt = now()
                lastRawTranscript = transcript.text
                lastDetectedLanguage = transcript.language
                lastInsertionMethod = nil
                lastDeliveryStatus = nil
                let text = TextPostProcessor.process(transcript.text, options: cfg.postProcessing)
                lastTranscript = text.trimmingCharacters(in: .whitespaces)

                guard !text.isEmpty else {
                    presenter.showMessage("Didn't catch that", for: MessageDuration.glance)
                    phase = .idle
                    onEvent?(.noSpeech)
                    return
                }

                let processedAt = now()
                phase = .inserting
                timeoutTask?.cancel()
                presenter.hide()
                let result = try await inserter.insert(text, strategy: cfg.insertionStrategy, destination: currentDestination)
                try Task.checkCancellation()
                let method = result.method
                lastDeliveryStatus = result.delivery
                lastTranscript = result.text.trimmingCharacters(in: .whitespaces)
                let deliveredAt = now()
                lastTiming = DictationTiming(
                    modelWait: modelReadyAt - releasedAt,
                    transcription: transcribedAt - modelReadyAt,
                    postProcessing: processedAt - transcribedAt,
                    insertion: deliveredAt - processedAt,
                    releaseToDelivery: deliveredAt - releasedAt
                )
                if result.delivery == .unverified {
                    presenter.showMessage(result.summary + ". Copy Last Transcript is available if needed.", for: MessageDuration.glance)
                }
                lastInsertionMethod = method
                lastDetectedLanguage = transcript.language
                lastError = nil
                log.info("Inserted \(text.count, privacy: .public) characters via \(method.rawValue, privacy: .public) (\(transcript.processingTime, privacy: .public) s)")
                phase = .idle
                onEvent?(.inserted(DictationOutcome(
                    timestamp: Date(),
                    characters: result.text.count,
                    words: DictationOutcome.wordCount(of: result.text),
                    recordedSeconds: recording.duration,
                    transcriptionSeconds: transcript.processingTime,
                    method: method,
                    model: cfg.model,
                    detectedLanguage: transcript.language,
                    delivery: result.delivery
                )))
                if recording.deviceIsBluetooth { onEvent?(.usedBluetoothInput) }
            } catch is CancellationError {
                // A cancelled operation never writes a late result or error.
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                presenter.showMessage(error.localizedDescription, for: MessageDuration.error)
                log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                phase = .idle
                onEvent?(.failed(error.localizedDescription))
            }
        }
    }

    private func releaseModel() {
        guard hasModelLease else { return }
        hasModelLease = false
        models.endUse()
    }

    func clearLastTranscript() {
        lastTranscript = nil
        lastRawTranscript = nil
        lastDetectedLanguage = nil
        lastInsertionMethod = nil
        lastDeliveryStatus = nil
        lastTiming = nil
        lastError = nil
    }

    /// Explicit recovery into a newly chosen destination; never re-runs cleanup.
    func pasteLastTranscript() {
        guard phase == .idle, !hasPendingWork, let text = lastTranscript, !text.isEmpty else { return }
        sampleTask?.cancel()
        var destination = inserter.captureDestination()
        let cfg = configuration(for: destination)
        destination?.newlinePreference = cfg.newlinePreference
        phase = .inserting
        sampleTask = Task { [weak self] in
            guard let self else { return }
            defer { phase = .idle
                sampleTask = nil
            }
            do {
                let result = try await inserter.insert(text, strategy: cfg.insertionStrategy, destination: destination)
                try Task.checkCancellation()
                lastInsertionMethod = result.method
                lastDeliveryStatus = result.delivery
                lastError = nil
                presenter.showMessage(result.summary, for: MessageDuration.glance)
            } catch {
                lastError = error.localizedDescription
                presenter.showMessage(error.localizedDescription, for: MessageDuration.error)
            }
        }
    }

    private func configuration(for destination: InsertionDestination?) -> DictationConfig {
        destinationConfig?(destination?.bundleIdentifier) ?? config()
    }
}
