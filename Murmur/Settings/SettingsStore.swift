import Foundation
import Combine

/// All user-configurable state, persisted to `UserDefaults` as JSON.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var hotkey: Hotkey { didSet { save(hotkey, key: .hotkey) } }
    @Published var inputDeviceUID: String? { didSet { save(inputDeviceUID, key: .inputDeviceUID) } }
    @Published var model: WhisperModel { didSet { save(model, key: .model) } }
    @Published var language: TranscriptionLanguage { didSet { save(language, key: .language) } }
    @Published var insertionStrategy: InsertionStrategy { didSet { save(insertionStrategy, key: .insertionStrategy) } }
    @Published var postProcessing: PostProcessingOptions { didSet { save(postProcessing, key: .postProcessing) } }
    @Published var maxRecordingSeconds: Double { didSet { save(maxRecordingSeconds, key: .maxRecordingSeconds) } }
    @Published var playSounds: Bool { didSet { save(playSounds, key: .playSounds) } }
    @Published var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, key: .hasCompletedOnboarding) } }

    private enum Key: String {
        case hotkey, inputDeviceUID, model, language, insertionStrategy
        case postProcessing, maxRecordingSeconds, playSounds, hasCompletedOnboarding
        var storageKey: String { "murmur.\(rawValue)" }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = Self.load(Hotkey.self, key: .hotkey, from: defaults) ?? .default
        inputDeviceUID = Self.load(String?.self, key: .inputDeviceUID, from: defaults) ?? nil
        model = Self.load(WhisperModel.self, key: .model, from: defaults) ?? .largeV3Turbo
        language = Self.load(TranscriptionLanguage.self, key: .language, from: defaults) ?? .auto
        insertionStrategy = Self.load(InsertionStrategy.self, key: .insertionStrategy, from: defaults) ?? .accessibilityThenPasteboard
        postProcessing = Self.load(PostProcessingOptions.self, key: .postProcessing, from: defaults) ?? PostProcessingOptions()
        maxRecordingSeconds = Self.load(Double.self, key: .maxRecordingSeconds, from: defaults) ?? 120
        playSounds = Self.load(Bool.self, key: .playSounds, from: defaults) ?? true
        hasCompletedOnboarding = Self.load(Bool.self, key: .hasCompletedOnboarding, from: defaults) ?? false
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.storageKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: Key, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key.storageKey) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
