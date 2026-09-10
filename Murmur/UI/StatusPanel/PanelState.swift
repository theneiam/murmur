import CoreGraphics
import Foundation

/// Where the floating status panel sits, in screen coordinates: the
/// horizontal centre and the bottom edge. Anchoring this way lets the pill
/// grow and shrink between states (idle, recording, message) without
/// drifting, and survives display changes via `resolved`.
struct PanelAnchor: Codable, Equatable {
    var centerX: CGFloat
    var bottomY: CGFloat

    /// Bottom centre of a screen's visible frame, a little above the Dock.
    static func `default`(for visibleFrame: CGRect) -> PanelAnchor {
        PanelAnchor(centerX: visibleFrame.midX, bottomY: visibleFrame.minY + 60)
    }

    func origin(for size: CGSize) -> CGPoint {
        CGPoint(x: centerX - size.width / 2, y: bottomY)
    }

    /// The anchor itself if a panel of `panelSize` placed there would be
    /// substantially on one of `screens` (visible frames), otherwise the
    /// default position on `fallback`. Guards against a position saved on
    /// a display that is no longer connected.
    func resolved(panelSize: CGSize, screens: [CGRect], fallback: CGRect) -> PanelAnchor {
        let frame = CGRect(origin: origin(for: panelSize), size: panelSize)
        let visibleEnough = screens.contains { screen in
            let overlap = screen.intersection(frame)
            guard !overlap.isNull else { return false }
            return overlap.width * overlap.height >= frame.width * frame.height * 0.6
        }
        return visibleEnough ? self : .default(for: fallback)
    }
}

/// What the panel shows while nothing is happening: just the glyph and the
/// name when ready, or the reason when Murmur cannot dictate right now.
struct StatusPanelIdle: Equatable {
    /// Empty when ready; otherwise the problem (permission missing, model
    /// not downloaded…), shown with a warning glyph.
    var hint: String
    var isWarning: Bool

    static func make(isReady: Bool, statusText: String) -> StatusPanelIdle {
        isReady
            ? StatusPanelIdle(hint: "", isWarning: false)
            : StatusPanelIdle(hint: statusText, isWarning: true)
    }
}

/// Transient: the panel appears for a dictation and fades out afterwards.
/// Persistent: the "status panel" setting — it stays on screen, shows an
/// idle state between dictations, can be dragged and remembers its spot.
enum PanelMode: Equatable {
    case transient
    case persistent
}

/// Everything the panel can show. `StatusPanel.render` is the only way in.
enum PanelState: Equatable {
    case hidden
    case idle(StatusPanelIdle)
    case recording
    /// Spinner with a label: "Transcribing…", "Loading model…".
    case working(String)
    /// Auto-dismisses after `duration`, then resolves to `resting`.
    case message(String, duration: TimeInterval)

    /// What the panel shows when nothing is happening: the idle status in
    /// persistent mode, nothing at all in transient mode.
    static func resting(mode: PanelMode, idle: StatusPanelIdle) -> PanelState {
        mode == .persistent ? .idle(idle) : .hidden
    }

    var isIdleOrHidden: Bool {
        switch self {
        case .idle, .hidden: return true
        case .recording, .working, .message: return false
        }
    }
}
