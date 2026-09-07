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

    let settings: SettingsStore
    let permissions: PermissionsManager
    let models: ModelManager
    let hotkeys: HotkeyManager
    let recorder: AudioRecorder
    let indicator: IndicatorWindowController

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "app")
    private var cancellables: Set<AnyCancellable> = []
    private var minimumUtterance: TimeInterval = 0.3

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
            .sink { [weak self] model in self?.models.activate(model) }
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

    var isReadyToDictate: Bool {
        permissions.allGranted && hotkeys.isRunning && isModelReady
    }

    /// One-line status for the menu bar.
    var statusText: String {
        if !permissions.accessibility { return "Accessibility permission needed" }
        if permissions.microphone != .authorized { return "Microphone permission needed" }
        if let hotkeyError { return hotkeyError }
        switch models.status(of: settings.model) {
        case .notDownloaded: return "Model not downloaded"
        case let .downloading(progress): return "Downloading model… \(Int(progress * 100))%"
        case .downloaded, .loading: return "Loading model…"
        case let .failed(message): return "Model error: \(message)"
        case .ready: break
        }
        switch phase {
        case .idle: return "Hold \(settings.hotkey.displayString) to dictate"
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

    /// Called from inside the CGEvent tap callback. Anything slow here stalls
    /// every keystroke on the system and can get the tap disabled, so only
    /// flip state and hop off the callback before starting the audio engine.
    private func hotkeyPressed() {
        guard phase == .idle else { return }
        phase = .starting
        DispatchQueue.main.async { [weak self] in self?.beginRecording() }
    }

    private func beginRecording() {
        guard phase == .starting else { return }

        guard permissions.microphone == .authorized else {
            phase = .idle
            indicator.showMessage("Microphone access is required")
            return
        }
        guard isModelReady else {
            phase = .idle
            switch models.status(of: settings.model) {
            case let .downloading(progress):
                indicator.showMessage("Downloading model… \(Int(progress * 100))%")
            case .loading, .downloaded:
                indicator.showMessage("Model is still loading…")
            default:
                indicator.showMessage("Choose and download a model in Settings")
            }
            return
        }

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
            indicator.hide()
            return
        }

        phase = .transcribing
        indicator.showTranscribing()

        let language = settings.language
        let options = settings.postProcessing
        let strategy = settings.insertionStrategy

        Task { [weak self] in
            guard let self else { return }
            do {
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
                try await TextInserter.insert(text, strategy: strategy)
                self.lastError = nil
                self.log.info("Inserted \(text.count, privacy: .public) characters (\(transcript.processingTime, privacy: .public) s)")
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
