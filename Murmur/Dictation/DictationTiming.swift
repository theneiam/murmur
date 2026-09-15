import Foundation

/// Per-session timing kept in memory. It contains no audio or transcript.
struct DictationTiming: Equatable {
    var modelWait: TimeInterval
    var transcription: TimeInterval
    var postProcessing: TimeInterval
    var insertion: TimeInterval
    var releaseToDelivery: TimeInterval
}
