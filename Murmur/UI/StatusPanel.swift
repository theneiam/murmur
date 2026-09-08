import Foundation
import CoreGraphics

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

/// What the panel shows while nothing is happening.
struct StatusPanelIdle: Equatable {
    var hint: String
    /// `true` when the hint is a problem (permission missing, model not
    /// downloaded) rather than the usual "hold the key" prompt.
    var isWarning: Bool

    static func make(isReady: Bool, hotkeyDisplay: String, statusText: String) -> StatusPanelIdle {
        isReady
            ? StatusPanelIdle(hint: "Hold \(hotkeyDisplay)", isWarning: false)
            : StatusPanelIdle(hint: statusText, isWarning: true)
    }
}
