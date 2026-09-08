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
    /// Minutes of inactivity after which the warm model is dropped from
    /// memory (it reloads on the next dictation). 0 = keep it loaded forever.
    @Published var unloadAfterIdleMinutes: Double { didSet { save(unloadAfterIdleMinutes, key: .unloadAfterIdleMinutes) } }
    @Published var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, key: .hasCompletedOnboarding) } }
    /// The one-time "Bluetooth microphone" hint has been shown.
    @Published var hasShownBluetoothHint: Bool { didSet { save(hasShownBluetoothHint, key: .hasShownBluetoothHint) } }
    /// Keep the dictation indicator on screen permanently as a status panel.
    @Published var showStatusPanel: Bool { didSet { save(showStatusPanel, key: .showStatusPanel) } }
    /// Where the user last dragged the status panel; `nil` = default spot.
    @Published var statusPanelAnchor: PanelAnchor? { didSet { save(statusPanelAnchor, key: .statusPanelAnchor) } }

    private enum Key: String {
        case hotkey, inputDeviceUID, model, language, insertionStrategy
        case postProcessing, maxRecordingSeconds, playSounds, hasCompletedOnboarding
        case unloadAfterIdleMinutes, hasShownBluetoothHint, showStatusPanel, statusPanelAnchor
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
        unloadAfterIdleMinutes = Self.load(Double.self, key: .unloadAfterIdleMinutes, from: defaults) ?? 30
        hasCompletedOnboarding = Self.load(Bool.self, key: .hasCompletedOnboarding, from: defaults) ?? false
        hasShownBluetoothHint = Self.load(Bool.self, key: .hasShownBluetoothHint, from: defaults) ?? false
        showStatusPanel = Self.load(Bool.self, key: .showStatusPanel, from: defaults) ?? false
        statusPanelAnchor = Self.load(PanelAnchor?.self, key: .statusPanelAnchor, from: defaults) ?? nil
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
