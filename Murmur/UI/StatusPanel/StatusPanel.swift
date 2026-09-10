import AppKit
import SwiftUI

/// The floating pill: a non-activating panel that never steals focus from
/// the app the user is dictating into.
///
/// Interface: `render(_:)` with a `PanelState`, `mode`, `idle` (what to show
/// between dictations in persistent mode), `anchor` / `onAnchorChange` for
/// the remembered position, and `push(level:)` for the level meter. It is
/// also the production adapter for `DictationPresenting`, so the dictation
/// pipeline drives it without knowing about windows.
///
/// Everything about windows — fades, the elapsed-time ticker, message
/// auto-dismiss, dragging, re-measuring after SwiftUI layout — is internal.
@MainActor
final class StatusPanel: DictationPresenting {
    private(set) var state: PanelState = .hidden

    var mode: PanelMode = .transient {
        didSet {
            guard mode != oldValue else { return }
            window?.ignoresMouseEvents = mode == .transient
            window?.isMovableByWindowBackground = mode == .persistent
            if state.isIdleOrHidden { render(.resting(mode: mode, idle: idle)) }
        }
    }

    /// Content of the idle state (persistent mode). Re-rendered on change.
    var idle = StatusPanelIdle(hint: "", isWarning: false) {
        didSet {
            guard idle != oldValue else { return }
            if case .idle = state { render(.idle(idle)) }
        }
    }

    /// Saved position (persistent mode). `nil` = default bottom centre.
    var anchor: PanelAnchor?
    /// Called after the user drags the panel, with the new anchor to persist.
    var onAnchorChange: ((PanelAnchor) -> Void)?

    private let model = StatusPanelModel()
    private var window: StatusPanelWindow?
    private var dismissWork: DispatchWorkItem?
    private var ticker: Timer?
    private var recordingStart: Date?
    private var moveObserver: NSObjectProtocol?
    /// Set while we move the panel ourselves so it is not mistaken for a drag.
    private var isRepositioning = false
    /// Incremented on every show/hide so a fade-out that finishes after a new
    /// `present()` doesn't order the panel out from under a fresh state.
    private var generation = 0

    // MARK: Interface

    func render(_ newState: PanelState) {
        dismissWork?.cancel()
        dismissWork = nil
        stopTicker()
        state = newState

        switch newState {
        case .hidden:
            orderOut()
        case .idle:
            model.state = newState
            present()
        case .recording:
            model.resetLevels()
            model.state = newState
            startTicker()
            present()
        case .working:
            model.state = newState
            present()
        case let .message(_, duration):
            model.state = newState
            present()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                render(.resting(mode: mode, idle: idle))
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func push(level: Float) {
        model.push(level: level)
    }

    // MARK: DictationPresenting

    func showRecording() { render(.recording) }
    func showWorking(_ label: String) { render(.working(label)) }
    func showMessage(_ text: String, for duration: TimeInterval) { render(.message(text, duration: duration)) }
    func hide() { render(.resting(mode: mode, idle: idle)) }
    func playCue(_ cue: SoundCue) { Sounds.play(cue) }

    // MARK: Ticker

    private func startTicker() {
        recordingStart = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = recordingStart else { return }
                model.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        recordingStart = nil
    }

    // MARK: Window

    private func orderOut() {
        guard let window, window.isVisible else { return }
        generation &+= 1
        let current = generation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // The completion handler is @Sendable; AppKit invokes it on the
            // main thread, so hop back into MainActor isolation explicitly.
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.window?.orderOut(nil)
            }
        }
    }

    private func present() {
        generation &+= 1
        let window = window ?? makeWindow()
        position(window)
        // SwiftUI applies the new state asynchronously; measure once more
        // after it has laid out so the pill fits its content exactly.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            position(window)
        }
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                window.animator().alphaValue = 1
            }
        } else {
            // Cancels any in-flight fade-out.
            window.animator().alphaValue = 1
            window.alphaValue = 1
        }
    }

    private func makeWindow() -> StatusPanelWindow {
        let window = StatusPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = mode == .transient
        window.isMovableByWindowBackground = mode == .persistent
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let host = DraggableHostingView(rootView: StatusPanelView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        self.window = window

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidMove() }
        }
        return window
    }

    private func windowDidMove() {
        guard mode == .persistent, !isRepositioning, let window else { return }
        let frame = window.frame
        let moved = PanelAnchor(centerX: frame.midX, bottomY: frame.minY)
        guard moved != anchor else { return }
        anchor = moved
        onAnchorChange?(moved)
    }

    /// Transient mode: bottom centre of the screen with keyboard focus.
    /// Persistent mode: the saved anchor, validated against the connected
    /// screens. Either way the pill is resized to fit its content first.
    private func position(_ window: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        var size = window.contentView?.fittingSize ?? window.frame.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 260, height: 70) }

        let target: PanelAnchor
        if mode == .persistent, let anchor {
            target = anchor.resolved(panelSize: size, screens: NSScreen.screens.map(\.visibleFrame), fallback: frame)
        } else {
            target = .default(for: frame)
        }
        isRepositioning = true
        window.setContentSize(size)
        window.setFrameOrigin(target.origin(for: size))
        isRepositioning = false
    }
}

/// Never becomes key or main, so dragging it never takes focus from the app
/// the user is typing in.
private final class StatusPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets a mouse-down anywhere on the SwiftUI content start a window drag
/// (`isMovableByWindowBackground` only applies where this returns true).
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}
