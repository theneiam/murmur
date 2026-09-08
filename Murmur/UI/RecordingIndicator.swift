import SwiftUI
import AppKit

/// View model for the floating indicator.
@MainActor
final class IndicatorModel: ObservableObject {
    enum State: Equatable {
        /// Status-panel mode only: nothing happening.
        case idle(StatusPanelIdle)
        case recording
        /// Spinner with a label: "Transcribing…", "Loading model…".
        case working(String)
        case message(String)
    }

    @Published var state: State = .recording
    @Published var levels: [Float] = Array(repeating: 0, count: IndicatorModel.barCount)
    @Published var elapsed: TimeInterval = 0

    static let barCount = 18

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
        elapsed = 0
    }
}

struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case let .idle(idle):
                Image(systemName: idle.isWarning ? "exclamationmark.triangle.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(idle.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text("Murmur")
                    .font(.system(size: 13, weight: .semibold))
                if !idle.hint.isEmpty {
                    Text(idle.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 260)
                }
            case .recording:
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: .red.opacity(0.6), radius: 4)
                Waveform(levels: model.levels)
                    .frame(width: 90, height: 22)
                Text(timeString(model.elapsed))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            case let .working(label):
                ProgressView()
                    .controlSize(.small)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            case let .message(text):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        // Two subtle layers instead of one big halo: a hairline contact
        // shadow and a soft, low-opacity lift.
        .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        .padding(8) // room for the shadow inside the transparent panel
        .animation(.easeInOut(duration: 0.15), value: model.state)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(3, CGFloat(levels[i]) * 22))
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}

/// A non-activating floating panel that never steals focus from the app the
/// user is dictating into.
///
/// Two modes. Transient (default): appears for a dictation, fades out after,
/// click-through, always at the bottom centre of the active screen.
/// Persistent (`isPersistent`, the "status panel" setting): stays on screen
/// showing an idle state between dictations, can be dragged, and remembers
/// where it was put via `anchor` / `onAnchorChange`.
@MainActor
final class IndicatorWindowController {
    let model = IndicatorModel()
    private var panel: StatusPanelWindow?
    private var hideWork: DispatchWorkItem?
    private var timer: Timer?
    private var recordingStart: Date?
    private var moveObserver: NSObjectProtocol?
    /// Set while we move the panel ourselves so it is not mistaken for a drag.
    private var isRepositioning = false

    var isPersistent = false {
        didSet {
            guard isPersistent != oldValue else { return }
            panel?.ignoresMouseEvents = !isPersistent
            panel?.isMovableByWindowBackground = isPersistent
            if isPersistent {
                if case .idle = model.state { present() } else if !(panel?.isVisible ?? false) { showIdle() }
            } else if case .idle = model.state {
                orderOut()
            }
        }
    }

    /// Saved position (persistent mode). `nil` = default bottom centre.
    var anchor: PanelAnchor?
    /// Called after the user drags the panel, with the new anchor to persist.
    var onAnchorChange: ((PanelAnchor) -> Void)?

    private var idle = StatusPanelIdle(hint: "", isWarning: false)

    /// Updates the idle content; re-renders immediately if idle is showing.
    func setIdle(_ newIdle: StatusPanelIdle) {
        guard newIdle != idle else { return }
        idle = newIdle
        if case .idle = model.state, isPersistent {
            model.state = .idle(idle)
            if let panel { position(panel) }
        }
    }

    func showIdle() {
        guard isPersistent else { return }
        hideWork?.cancel()
        timer?.invalidate()
        timer = nil
        recordingStart = nil
        model.state = .idle(idle)
        present()
    }

    func showRecording() {
        hideWork?.cancel()
        model.resetLevels()
        model.state = .recording
        recordingStart = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStart else { return }
                self.model.elapsed = Date().timeIntervalSince(start)
            }
        }
        present()
    }

    func showWorking(_ label: String) {
        hideWork?.cancel()
        timer?.invalidate()
        model.state = .working(label)
        present()
    }

    func showMessage(_ text: String, for duration: TimeInterval = 2.5) {
        hideWork?.cancel()
        timer?.invalidate()
        model.state = .message(text)
        present()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func push(level: Float) {
        model.push(level: level)
    }

    /// Incremented on every show/hide so a fade-out that finishes after a new
    /// `present()` doesn't order the panel out from under a fresh recording.
    private var generation = 0

    /// Ends the current transient state: fades out, or in persistent mode
    /// returns to the idle status.
    func hide() {
        if isPersistent {
            showIdle()
            return
        }
        orderOut()
    }

    private func orderOut() {
        timer?.invalidate()
        timer = nil
        recordingStart = nil
        guard let panel, panel.isVisible else { return }
        generation &+= 1
        let current = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The completion handler is @Sendable; AppKit invokes it on the
            // main thread, so hop back into MainActor isolation explicitly.
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    // MARK: Panel

    private func present() {
        generation &+= 1
        let panel = panel ?? makePanel()
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            // Cancels any in-flight fade-out.
            panel.animator().alphaValue = 1
            panel.alphaValue = 1
        }
    }

    private func makePanel() -> StatusPanelWindow {
        let panel = StatusPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = !isPersistent
        panel.isMovableByWindowBackground = isPersistent
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let host = DraggableHostingView(rootView: IndicatorView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidMove() }
        }
        return panel
    }

    private func panelDidMove() {
        guard isPersistent, !isRepositioning, let panel else { return }
        let frame = panel.frame
        let moved = PanelAnchor(centerX: frame.midX, bottomY: frame.minY)
        guard moved != anchor else { return }
        anchor = moved
        onAnchorChange?(moved)
    }

    /// Transient mode: bottom centre of the screen with keyboard focus.
    /// Persistent mode: the saved anchor, validated against the connected
    /// screens. Either way the pill is resized to fit its content first.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        var size = panel.contentView?.fittingSize ?? panel.frame.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 260, height: 70) }

        let target: PanelAnchor
        if isPersistent, let anchor {
            target = anchor.resolved(panelSize: size, screens: NSScreen.screens.map(\.visibleFrame), fallback: frame)
        } else {
            target = .default(for: frame)
        }
        isRepositioning = true
        panel.setContentSize(size)
        panel.setFrameOrigin(target.origin(for: size))
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
