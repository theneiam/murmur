import Foundation
import AppKit
import Combine
import os

/// The app's coordinator: wires hotkey → recorder → engine → inserter and
/// owns the push-to-talk state machine.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        /// Hotkey pressed; the audio engine is spinning up.
        case starting
        case recording
        case transcribing
        case inserting
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastError: String?
    @Published private(set) var hotkeyError: String?
    @Published private(set) var lastInsertionMethod: InsertionMethod?

    let settings: SettingsStore
    let permissions: PermissionsManager
    let models: ModelManager
    let hotkeys: HotkeyManager
    let recorder: AudioRecorder
    let indicator: IndicatorWindowController

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "app")
    private var cancellables: Set<AnyCancellable> = []
    private var minimumUtterance: TimeInterval = 0.3
    private var idleUnloadTask: Task<Void, Never>?

    private init() {
        settings = SettingsStore()
        permissions = PermissionsManager()
        models = ModelManager()
        hotkeys = HotkeyManager(hotkey: settings.hotkey)
        recorder = AudioRecorder()
        indicator = IndicatorWindowController()

        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onCancel = { [weak self] in self?.cancelRecording() }

        recorder.onLevel = { [weak self] level in self?.indicator.push(level: level) }
        recorder.onAutoStop = { [weak self] recording in
            self?.log.info("Recording hit the maximum duration; transcribing")
            self?.finish(recording)
        }

        settings.$hotkey
            .removeDuplicates()
            .sink { [weak self] hotkey in self?.hotkeys.hotkey = hotkey }
            .store(in: &cancellables)

        // `dropFirst` so launching never triggers a download by itself; the
        // initial activation happens in `start()` only for a model that is
        // already on disk.
        settings.$model
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] model in
                self?.models.activate(model)
                self?.scheduleIdleUnload()
            }
            .store(in: &cancellables)

        settings.$unloadAfterIdleMinutes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleIdleUnload() }
            .store(in: &cancellables)

        // `statusText` / `isReadyToDictate` derive from the child objects, so
        // forward their change notifications to views observing only AppState.
        models.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        permissions.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Whenever Accessibility becomes available (e.g. granted during
        // onboarding), bring the hotkey listener up.
        permissions.$accessibility
            .removeDuplicates()
            .sink { [weak self] trusted in
                guard let self else { return }
                if trusted { self.startHotkeyListener() } else { self.hotkeys.stop() }
            }
            .store(in: &cancellables)
    }

    // MARK: Startup

    func start() {
        permissions.refresh()
        startHotkeyListener()
        if models.isDownloaded(settings.model) {
            models.activate(settings.model)
            scheduleIdleUnload()
        }
        // Keep re-checking permissions so a grant made in System Settings is
        // picked up without relaunching.
        permissions.startPolling(interval: 2.0)
    }

    /// Readiness is tied to the *selected* model: switching to a model that is
    /// not downloaded must not silently keep dictating with the previous one.
    var isModelReady: Bool {
        models.activeModel == settings.model && models.isReady
    }

    /// The selected model is warm, loading, or on disk and loadable on demand.
    /// Recording never waits for the model; transcription does.
    var isModelAvailable: Bool {
        models.isAvailable(settings.model)
    }

    var isReadyToDictate: Bool {
        permissions.allGranted && hotkeys.isRunning && isModelAvailable
    }

    static let bluetoothHint = "You're dictating through a Bluetooth headset. Its microphone takes about a second to switch on, so the start of each dictation may be cut. For dictation the built-in microphone is usually better — Settings → Audio."

    // MARK: Idle unload

    /// (Re)arms the idle timer. Fires only when nothing is in progress; the
    /// next dictation reloads the model while the user is still speaking.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        let minutes = settings.unloadAfterIdleMinutes
        guard minutes > 0 else { return }
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard let self, !Task.isCancelled, self.phase == .idle else { return }
            await self.models.unloadForIdle()
        }
    }

    // MARK: Insertion test (Settings → General)

    /// Inserts a sample sentence into whatever app is frontmost after a short
    /// countdown and reports which path delivered it, so insertion can be
    /// checked per app without dictating.
    func runInsertionTest() {
        guard phase == .idle else { return }
        let strategy = settings.insertionStrategy
        indicator.showMessage("Click into the app you want to test — inserting a sample in 3 s…", for: 3)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.phase == .idle else { return }
            let sample = "Murmur insertion test at \(Date().formatted(date: .omitted, time: .standard)). "
            do {
                let method = try await TextInserter.insert(sample, strategy: strategy)
                self.lastInsertionMethod = method
                self.log.info("Insertion test: \(method.rawValue, privacy: .public)")
                self.indicator.showMessage("Inserted via \(method.displayName). Check that the text landed exactly once.", for: 5)
            } catch {
                self.indicator.showMessage(error.localizedDescription, for: 5)
            }
        }
    }

    /// One-line status for the menu bar.
    var statusText: String {
        if !permissions.accessibility { return "Accessibility permission needed" }
        if permissions.microphone != .authorized { return "Microphone permission needed" }
        if let hotkeyError { return hotkeyError }
        switch models.status(of: settings.model) {
        case .notDownloaded: return "Model not downloaded"
        case let .downloading(progress): return "Downloading model… \(Int(progress * 100))%"
        case let .failed(message): return "Model error: \(message)"
        case .ready, .downloaded, .loading: break
        }
        switch phase {
        case .idle:
            let base = "Hold \(settings.hotkey.displayString) to dictate"
            switch models.status(of: settings.model) {
            case .loading: return base + " (model loading…)"
            case .downloaded: return base + " (model loads on first use)"
            default: return base
            }
        case .starting, .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting text…"
        }
    }

    private func startHotkeyListener() {
        guard !hotkeys.isRunning else { return }
        do {
            try hotkeys.start()
            hotkeyError = nil
        } catch {
            hotkeyError = error.localizedDescription
            log.error("Hotkey listener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Push-to-talk state machine

    /// Delivered on the main queue by `HotkeyManager`, already off the event
    /// tap thread, so it is safe to bring the audio engine up right here.
    private func hotkeyPressed() {
        guard phase == .idle else { return }
        phase = .starting
        beginRecording()
    }

    private func beginRecording() {
        guard phase == .starting else { return }

        guard permissions.microphone == .authorized else {
            phase = .idle
            indicator.showMessage("Microphone access is required")
            return
        }
        // Recording does not need the model. If it is on disk but cold
        // (first use, or dropped after the idle timeout) start loading now so
        // it warms up while the user speaks; `finish` waits for it.
        switch models.status(of: settings.model) {
        case .ready, .loading:
            break
        case .downloaded:
            models.activate(settings.model)
        case let .downloading(progress):
            phase = .idle
            indicator.showMessage("Downloading model… \(Int(progress * 100))%")
            return
        case let .failed(message):
            phase = .idle
            indicator.showMessage("Model error: \(message)", for: 4)
            return
        case .notDownloaded:
            phase = .idle
            indicator.showMessage("Choose and download a model in Settings")
            return
        }
        idleUnloadTask?.cancel()

        do {
            try recorder.start(inputDeviceUID: settings.inputDeviceUID, maxDuration: settings.maxRecordingSeconds)
            phase = .recording
            indicator.showRecording()
            if settings.playSounds { Sounds.play(.start) }
        } catch {
            phase = .idle
            lastError = error.localizedDescription
            indicator.showMessage(error.localizedDescription)
        }
    }

    private func hotkeyReleased() {
        switch phase {
        case .starting:
            // Released before the engine came up: a tap, not an utterance.
            phase = .idle
        case .recording:
            let recording = recorder.stop()
            finish(recording)
        default:
            break
        }
    }

    private func cancelRecording() {
        switch phase {
        case .starting:
            phase = .idle
        case .recording:
            recorder.stop()
            phase = .idle
            indicator.hide()
        default:
            break
        }
    }

    private func finish(_ recording: Recording) {
        guard phase == .recording else { return }
        if settings.playSounds { Sounds.play(.stop) }

        guard recording.duration >= minimumUtterance else {
            phase = .idle
            if recording.isSilentCaptureFailure(minimumUtterance: minimumUtterance) {
                let message = recording.silentCaptureFailureMessage
                lastError = message
                indicator.showMessage(message, for: 5)
            } else {
                indicator.hide()
            }
            return
        }

        phase = .transcribing
        indicator.showWorking(isModelReady ? "Transcribing…" : "Loading model…")

        let language = settings.language
        let options = settings.postProcessing
        let strategy = settings.insertionStrategy
        let selectedModel = settings.model

        Task { [weak self] in
            guard let self else { return }
            defer { self.scheduleIdleUnload() }
            do {
                if !self.isModelReady {
                    let ready = await self.models.awaitActivation()
                    guard ready, self.models.activeModel == selectedModel else {
                        throw TranscriptionError.modelNotLoaded
                    }
                    self.indicator.showWorking("Transcribing…")
                }
                let engine = self.models.engine
                let samples = recording.samples
                // A stalled CoreML call must never leave the app stuck in
                // `.transcribing` with no way back to idle.
                let transcript = try await withThrowingTaskGroup(of: Transcript.self) { group in
                    group.addTask { try await engine.transcribe(samples: samples, language: language) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(90))
                        throw TranscriptionError.timedOut
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                let text = TextPostProcessor.process(transcript.text, options: options)
                self.lastTranscript = text.trimmingCharacters(in: .whitespaces)

                guard !text.isEmpty else {
                    self.indicator.showMessage("Didn't catch that", for: 1.2)
                    self.phase = .idle
                    return
                }

                self.phase = .inserting
                self.indicator.hide()
                let method = try await TextInserter.insert(text, strategy: strategy)
                self.lastInsertionMethod = method
                self.lastError = nil
                self.log.info("Inserted \(text.count, privacy: .public) characters via \(method.rawValue, privacy: .public) (\(transcript.processingTime, privacy: .public) s)")
                if recording.deviceIsBluetooth, !self.settings.hasShownBluetoothHint {
                    self.settings.hasShownBluetoothHint = true
                    self.indicator.showMessage(Self.bluetoothHint, for: 7)
                }
            } catch {
                self.lastError = error.localizedDescription
                self.indicator.showMessage(error.localizedDescription, for: 3)
                self.log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            }
            self.phase = .idle
        }
    }
}

/// Subtle start/stop cues using system sounds (no bundled assets needed).
/// The `NSSound` instances are kept alive: `play()` is asynchronous and a
/// sound released at the end of the statement may never be heard.
@MainActor
enum Sounds {
    enum Cue { case start, stop }

    private static let start = NSSound(named: "Tink")
    private static let stop = NSSound(named: "Pop")

    static func play(_ cue: Cue) {
        let sound = cue == .start ? start : stop
        sound?.stop()
        sound?.play()
    }
}
