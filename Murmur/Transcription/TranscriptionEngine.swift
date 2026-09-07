import Foundation

struct Transcript {
    let text: String
    /// ISO 639-1 code reported by the model (useful when auto-detecting).
    let language: String?
    let processingTime: TimeInterval
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case modelFolderMissing(WhisperModel)
    case timedOut
    case failed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No speech model is loaded yet."
        case .timedOut:
            return "Transcription took too long and was cancelled."
        case let .modelFolderMissing(model):
            return "The \(model.displayName) model files are missing. Download it again from Settings."
        case let .failed(underlying):
            return "Transcription failed: \(underlying.localizedDescription)"
        }
    }
}

/// Abstraction over the local speech-to-text backend so the app is not tied
/// to WhisperKit. `WhisperKitEngine` is the only implementation today; a
/// whisper.cpp-backed engine would slot in here.
protocol TranscriptionEngine: AnyObject, Sendable {
    /// Loads and pre-warms a model. Replaces any previously loaded model.
    func load(model: WhisperModel, folder: URL, tokenizerFolder: URL) async throws
    func unload() async
    var loadedModel: WhisperModel? { get async }
    /// `samples` must be 16 kHz mono Float32.
    func transcribe(samples: [Float], language: TranscriptionLanguage) async throws -> Transcript
}
