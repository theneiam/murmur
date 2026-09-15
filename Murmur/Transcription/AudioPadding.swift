import Foundation

/// WhisperKit's decode loop requires strictly more than 16 000 frames of
/// content (1.0 s at 16 kHz); at or below that it returns nothing at all.
/// Murmur's own floor is 0.3 s, so without this every utterance between
/// 0.3 s and 1.0 s was recorded, "transcribed" to an empty string and
/// reported as "Didn't catch that" — exactly the range short confirmations
/// live in ("да", "ага", "ok", "ship it").
///
/// Padding with silence is free: the mel window is zero-padded to 30 s
/// regardless of how much audio it is given.
enum AudioPadding {
    /// 1.1 s — comfortably past the 16 000-frame floor.
    static let minimumFrames = 17_600

    static func padded(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty, samples.count < minimumFrames else { return samples }
        return samples + [Float](repeating: 0, count: minimumFrames - samples.count)
    }
}
