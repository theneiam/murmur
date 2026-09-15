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
    @Published private(set) var isTestingMicrophone = false

    let settings: SettingsStore
    let permissions: PermissionsManager
    let models: ModelManager
    let hotkeys: HotkeyManager
    let recorder: AudioRecorder
    let statusPanel: StatusPanel
    let stats: StatsStore
    let session: DictationSession

    // Forwarded from the session so views observing only AppState keep working.
    var phase: Phase { session.phase }
    var lastTranscript: String? { session.lastTranscript }
    var lastRawTranscript: String? { session.lastRawTranscript }
    var lastDeliveryStatus: DeliveryStatus? { session.lastDeliveryStatus }
    var lastTiming: DictationTiming? { session.lastTiming }
    var lastError: String? { session.lastError }
    var lastInsertionMethod: InsertionMethod? { session.lastInsertionMethod }
    var lastDetectedLanguage: String? { session.lastDetectedLanguage }

    private let log = Logger.murmur("app")
    private var onboardingWindow: OnboardingWindowController?
    private var statisticsWindow: StatsWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var idleUnloadTask: Task<Void, Never>?
    private var hasStarted = false

    private init() {
        settings = SettingsStore()
        permissions = PermissionsManager()
        models = ModelManager()
        hotkeys = HotkeyManager(hotkey: settings.hotkey)
        recorder = AudioRecorder()
        recorder.preferredInputDeviceUIDs = settings.preferredInputDeviceUIDs
        statusPanel = StatusPanel()
        stats = StatsStore()
        stats.isEnabled = settings.collectStatistics

        let settings = settings, permissions = permissions
        session = DictationSession(
            recorder: recorder,
            models: models,
            inserter: StrategyInserter.live(),
            presenter: statusPanel,
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
            },
            destinationConfig: { bundleIdentifier in
                let resolved = settings.resolvedAppSettings(for: bundleIdentifier)
                return DictationConfig(
                    model: settings.model,
                    language: resolved.language,
                    postProcessing: resolved.postProcessing,
                    insertionStrategy: resolved.insertionStrategy,
                    inputDeviceUID: settings.inputDeviceUID,
                    maxRecordingSeconds: settings.maxRecordingSeconds,
                    playSounds: settings.playSounds,
                    microphoneAuthorized: permissions.microphone == .authorized,
                    newlinePreference: resolved.newlinePreference
                )
            }
        )

        hotkeys.pasteLastHotkey = settings.pasteLastHotkey
        hotkeys.copyLastHotkey = settings.copyLastHotkey
        hotkeys.verbatimHotkey = settings.verbatimHotkey
        hotkeys.onPress = { [weak self] in
            guard let self, !isTestingMicrophone else { return }
            session.press()
        }
        hotkeys.onVerbatimPress = { [weak self] in
            guard let self, !isTestingMicrophone else { return }
            session.press(verbatim: true)
        }
        hotkeys.onPasteLast = { [weak self] in self?.session.pasteLastTranscript() }
        hotkeys.onCopyLast = { [weak self] in self?.copyLastTranscript() }
        hotkeys.onRelease = { [weak self] in self?.session.release() }
        hotkeys.onCancel = { [weak self] in self?.session.cancel() }

        session.onEvent = { [weak self] event in self?.handle(event) }
        settings.$collectStatistics
            .removeDuplicates()
            .sink { [weak self] enabled in self?.stats.isEnabled = enabled }
            .store(in: &cancellables)
        stats.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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

        Publishers.CombineLatest(session.$phase, session.$hasPendingWork)
            .sink { [weak self] phase, pending in
                self?.hotkeys.cancellationEnabled = phase == .transcribing || phase == .inserting || pending
            }
            .store(in: &cancellables)

        settings.$hotkey
            .removeDuplicates()
            .sink { [weak self] hotkey in self?.hotkeys.hotkey = hotkey }
            .store(in: &cancellables)

        settings.$pasteLastHotkey
            .sink { [weak self] in self?.hotkeys.pasteLastHotkey = $0 }
            .store(in: &cancellables)
        settings.$copyLastHotkey
            .sink { [weak self] in self?.hotkeys.copyLastHotkey = $0 }
            .store(in: &cancellables)
        settings.$verbatimHotkey
            .sink { [weak self] in self?.hotkeys.verbatimHotkey = $0 }
            .store(in: &cancellables)
        settings.$preferredInputDeviceUIDs
            .sink { [weak self] in self?.recorder.preferredInputDeviceUIDs = $0 }
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

        statusPanel.onAnchorChange = { [weak self] anchor in self?.settings.statusPanelAnchor = anchor }

        // Status panel: its mode and idle content derive from exactly these
        // published values. `@Published` emits from `willSet`, so hop to the
        // next main-queue turn and read the settled values; no debounce.
        Publishers.MergeMany(
            permissions.$accessibility.map { _ in () }.eraseToAnyPublisher(),
            permissions.$microphone.map { _ in () }.eraseToAnyPublisher(),
            models.$statuses.map { _ in () }.eraseToAnyPublisher(),
            models.$activeModel.map { _ in () }.eraseToAnyPublisher(),
            settings.$hotkey.map { _ in () }.eraseToAnyPublisher(),
            settings.$model.map { _ in () }.eraseToAnyPublisher(),
            settings.$showStatusPanel.map { _ in () }.eraseToAnyPublisher(),
            settings.$statusPanelAnchor.map { _ in () }.eraseToAnyPublisher(),
            $hotkeyError.map { _ in () }.eraseToAnyPublisher(),
            $isTestingMicrophone.map { _ in () }.eraseToAnyPublisher(),
            session.$phase.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshStatusPanel() }
        .store(in: &cancellables)

        // Whenever Accessibility becomes available (e.g. granted during
        // onboarding), bring the hotkey listener up.
        permissions.$accessibility
            .removeDuplicates()
            .sink { [weak self] trusted in
                guard let self else { return }
                guard hasStarted else { return }
                if trusted { startHotkeyListener() } else { hotkeys.stop() }
            }
            .store(in: &cancellables)
    }

    // MARK: Startup

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
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

    /// Pushes the mode, anchor and idle content to the status panel. Cheap
    /// and idempotent: the panel re-renders only when a value changed.
    private func refreshStatusPanel() {
        statusPanel.anchor = settings.statusPanelAnchor
        statusPanel.idle = StatusPanelIdle.make(isReady: isReadyToDictate, statusText: statusText)
        statusPanel.mode = settings.showStatusPanel ? .persistent : .transient
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

    // MARK: Windows

    //
    // Opened from here, never via `NSApp.delegate as? AppDelegate`: under
    // `@NSApplicationDelegateAdaptor`, `NSApp.delegate` is SwiftUI's private
    // wrapper (also called `AppDelegate`), so that cast is always nil and the
    // menu action silently does nothing.

    func showOnboarding() {
        if onboardingWindow == nil { onboardingWindow = OnboardingWindowController() }
        onboardingWindow?.show()
    }

    func showStatistics() {
        if statisticsWindow == nil { statisticsWindow = StatsWindowController() }
        statisticsWindow?.show()
    }

    func copyLastTranscript() {
        guard let text = lastTranscript, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusPanel.showMessage("Last transcript copied.", for: MessageDuration.glance)
    }

    /// Microphone testing owns a separate recorder. Suspend the global key
    /// listener so a test and a dictation can never compete for the input.
    func setMicrophoneTesting(_ testing: Bool) {
        guard testing != isTestingMicrophone else { return }
        isTestingMicrophone = testing
        if testing {
            session.cancel()
            hotkeys.stop()
        } else if permissions.accessibility {
            startHotkeyListener()
        }
    }

    /// Current statistics, for the menu and the Statistics window.
    var statsSummary: StatsSummary {
        StatsSummary.make(days: stats.days, calendar: .current, now: Date())
    }

    // MARK: Dictation events

    private func handle(_ event: DictationEvent) {
        switch event {
        case .usedBluetoothInput:
            guard !settings.hasShownBluetoothHint else { return }
            settings.hasShownBluetoothHint = true
            statusPanel.showMessage(Self.bluetoothHint, for: MessageDuration.hint)
        case let .inserted(outcome):
            stats.record(outcome)
        case .noSpeech, .failed:
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
        if isTestingMicrophone { return "Testing microphone…" }
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
        guard !isTestingMicrophone else { return }
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
