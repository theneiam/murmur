import AppKit
import Combine
import Foundation
import os

/// The app's composition root: constructs the subsystems, wires the hotkey
/// to the `DictationSession`, and owns app-level policies (permissions →
/// hotkey listener, model activation on settings change, idle unload, the
/// status panel). The push-to-talk pipeline itself lives in
/// `DictationSession`.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    typealias Phase = DictationSession.Phase

    @Published private(set) var hotkeyError: String?

    let settings: SettingsStore
    let permissions: PermissionsManager
    let models: ModelManager
    let hotkeys: HotkeyManager
    let recorder: AudioRecorder
    let indicator: IndicatorWindowController
    let session: DictationSession

    // Forwarded from the session so views observing only AppState keep working.
    var phase: Phase { session.phase }
    var lastTranscript: String? { session.lastTranscript }
    var lastError: String? { session.lastError }
    var lastInsertionMethod: InsertionMethod? { session.lastInsertionMethod }

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "app")
    private var cancellables: Set<AnyCancellable> = []
    private var idleUnloadTask: Task<Void, Never>?

    private init() {
        settings = SettingsStore()
        permissions = PermissionsManager()
        models = ModelManager()
        hotkeys = HotkeyManager(hotkey: settings.hotkey)
        recorder = AudioRecorder()
        indicator = IndicatorWindowController()

        let settings = settings, permissions = permissions
        session = DictationSession(
            recorder: recorder,
            models: models,
            inserter: DefaultTextInserter(),
            presenter: indicator,
            config: {
                DictationConfig(
                    model: settings.model,
                    language: settings.language,
                    postProcessing: settings.postProcessing,
                    insertionStrategy: settings.insertionStrategy,
                    inputDeviceUID: settings.inputDeviceUID,
                    maxRecordingSeconds: settings.maxRecordingSeconds,
                    playSounds: settings.playSounds,
                    microphoneAuthorized: permissions.microphone == .authorized
                )
            }
        )

        hotkeys.onPress = { [weak self] in self?.session.press() }
        hotkeys.onRelease = { [weak self] in self?.session.release() }
        hotkeys.onCancel = { [weak self] in self?.session.cancel() }

        session.onEvent = { [weak self] event in self?.handle(event) }
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Idle unload: pause while a dictation is in progress, re-arm after.
        session.$phase
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] phase in
                if phase == .idle { self?.scheduleIdleUnload() } else { self?.idleUnloadTask?.cancel() }
            }
            .store(in: &cancellables)

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

        indicator.onAnchorChange = { [weak self] anchor in self?.settings.statusPanelAnchor = anchor }

        // Status panel: idle content depends on permissions, model state,
        // hotkey and phase. objectWillChange fires *before* the change, so
        // coalesce briefly and read the new values afterwards.
        Publishers.MergeMany(
            models.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            permissions.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            session.$phase.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.refreshStatusPanel() }
        .store(in: &cancellables)

        // Whenever Accessibility becomes available (e.g. granted during
        // onboarding), bring the hotkey listener up.
        permissions.$accessibility
            .removeDuplicates()
            .sink { [weak self] trusted in
                guard let self else { return }
                if trusted { startHotkeyListener() } else { hotkeys.stop() }
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
        refreshStatusPanel()
    }

    // MARK: Status panel

    /// Pushes the current idle content and the on/off setting to the
    /// indicator. Cheap and idempotent; called on every relevant change.
    private func refreshStatusPanel() {
        indicator.anchor = settings.statusPanelAnchor
        indicator.setIdle(StatusPanelIdle.make(isReady: isReadyToDictate, statusText: statusText))
        indicator.isPersistent = settings.showStatusPanel
        if settings.showStatusPanel, phase == .idle { indicator.showIdle() }
    }

    /// Everything a dictation needs right now: permissions, the hotkey
    /// listener, and a model that is not blocked (warm, cold or loading all
    /// work — recording never waits for the model, transcription does).
    var isReadyToDictate: Bool {
        guard permissions.allGranted, hotkeys.isRunning else { return false }
        if case .blocked = models.availability(of: settings.model) { return false }
        return true
    }

    static let bluetoothHint = "You're dictating through a Bluetooth headset. Its microphone takes about a second to switch on, so the start of each dictation may be cut. For dictation the built-in microphone is usually better — Settings → Audio."

    // MARK: Dictation events

    private func handle(_ event: DictationEvent) {
        switch event {
        case .usedBluetoothInput:
            guard !settings.hasShownBluetoothHint else { return }
            settings.hasShownBluetoothHint = true
            indicator.showMessage(Self.bluetoothHint, for: 7)
        case .inserted, .noSpeech, .failed:
            break
        }
    }

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
            guard let self, !Task.isCancelled, phase == .idle else { return }
            await models.unloadForIdle()
        }
    }

    /// One-line status for the menu bar.
    var statusText: String {
        if !permissions.accessibility { return "Accessibility permission needed" }
        if permissions.microphone != .authorized { return "Microphone permission needed" }
        if let hotkeyError { return hotkeyError }
        let availability = models.availability(of: settings.model)
        if case let .blocked(reason) = availability { return reason }
        switch phase {
        case .idle:
            let base = "Hold \(settings.hotkey.displayString) to dictate"
            switch availability {
            case .loading: return base + " (model loading…)"
            case .cold: return base + " (model loads on first use)"
            case .warm, .blocked: return base
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
}
