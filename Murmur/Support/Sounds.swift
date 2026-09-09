import AppKit

/// Subtle start/stop cues using system sounds (no bundled assets needed).
/// The `NSSound` instances are kept alive: `play()` is asynchronous and a
/// sound released at the end of the statement may never be heard.
@MainActor
enum Sounds {
    private static let start = NSSound(named: "Tink")
    private static let stop = NSSound(named: "Pop")

    static func play(_ cue: SoundCue) {
        let sound = cue == .start ? start : stop
        sound?.stop()
        sound?.play()
    }
}
