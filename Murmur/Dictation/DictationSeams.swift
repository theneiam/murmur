import Foundation

// The seams `DictationSession` depends on. Each has one real adapter in the
// app and one fake in MurmurTests — that is what makes the push-to-talk
// pipeline testable through its own interface.

// MARK: Audio

protocol AudioCapturing: AnyObject {
    /// Called on the main thread with a level in 0…1.
    var onLevel: ((Float) -> Void)? { get set }
    /// Called on the main thread when the maximum duration is reached.
    var onAutoStop: ((Recording) -> Void)? { get set }
    func start(inputDeviceUID: String?, maxDuration: TimeInterval) throws
    @discardableResult
    func stop() -> Recording
}

extension AudioRecorder: AudioCapturing {}

// MARK: Models

/// Whether the selected model can serve the next dictation.
enum ModelAvailability: Equatable {
    /// Loaded and ready; transcription starts immediately.
    case warm
    /// On disk but not loaded; `activate` while recording, wait in `finish`.
    case cold
    /// A load is in flight.
    case loading
    /// Cannot dictate; `reason` is user-facing.
    case blocked(reason: String)
}

@MainActor
protocol ModelProviding: AnyObject {
    var engine: any TranscriptionEngine { get }
    func availability(of model: WhisperModel) -> ModelAvailability
    func activate(_ model: WhisperModel)
    /// Waits for in-flight activation and reports whether `model` is warm.
    func awaitActivation(of model: WhisperModel) async -> Bool
}

extension ModelManager: ModelProviding {}

// MARK: Insertion

@MainActor
protocol TextInserting: AnyObject {
    func insert(_ text: String, strategy: InsertionStrategy) async throws -> InsertionMethod
}

/// Production adapter over the strategy switch in `TextInserter`.
@MainActor
final class DefaultTextInserter: TextInserting {
    func insert(_ text: String, strategy: InsertionStrategy) async throws -> InsertionMethod {
        try await TextInserter.insert(text, strategy: strategy)
    }
}

// MARK: Presentation

enum SoundCue { case start, stop }

@MainActor
protocol DictationPresenting: AnyObject {
    func showRecording()
    func showWorking(_ label: String)
    func showMessage(_ text: String, for duration: TimeInterval)
    func hide()
    func push(level: Float)
    func playCue(_ cue: SoundCue)
}

// MARK: Configuration & events

/// Everything a single dictation needs from settings and permissions,
/// captured when the key goes down so a settings change mid-dictation cannot
/// mix two configurations.
struct DictationConfig: Equatable {
    var model: WhisperModel
    var language: TranscriptionLanguage
    var postProcessing: PostProcessingOptions
    var insertionStrategy: InsertionStrategy
    var inputDeviceUID: String?
    var maxRecordingSeconds: TimeInterval
    var playSounds: Bool
    var microphoneAuthorized: Bool
}

/// One-off outcomes the app may want to react to (log, hint, metrics-free
/// bookkeeping). Continuous state is on the session's published properties.
enum DictationEvent: Equatable {
    case inserted(characters: Int, method: InsertionMethod)
    case noSpeech
    case failed(String)
    /// The recording came from a Bluetooth headset (fires after `inserted`).
    case usedBluetoothInput
}
