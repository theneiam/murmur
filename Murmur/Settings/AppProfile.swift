import Foundation

/// Explicit output choices for one destination app. A profile stores a copy
/// of the choices the user made so later global changes do not silently alter
/// that app's behavior.
struct AppProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var isEnabled: Bool
    var language: TranscriptionLanguage
    var insertionStrategy: InsertionStrategy
    var postProcessing: PostProcessingOptions
    var newlinePreference: NewlinePreference

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        isEnabled: Bool = true,
        language: TranscriptionLanguage,
        insertionStrategy: InsertionStrategy,
        postProcessing: PostProcessingOptions,
        newlinePreference: NewlinePreference = .automatic
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.language = language
        self.insertionStrategy = insertionStrategy
        self.postProcessing = postProcessing
        self.newlinePreference = newlinePreference
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, displayName, isEnabled, language
        case insertionStrategy, postProcessing, newlinePreference
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        displayName = try values.decode(String.self, forKey: .displayName)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        language = try values.decodeIfPresent(TranscriptionLanguage.self, forKey: .language) ?? .auto
        insertionStrategy = try values.decodeIfPresent(InsertionStrategy.self, forKey: .insertionStrategy) ?? .accessibilityThenPasteboard
        postProcessing = try values.decodeIfPresent(PostProcessingOptions.self, forKey: .postProcessing) ?? PostProcessingOptions()
        newlinePreference = try values.decodeIfPresent(NewlinePreference.self, forKey: .newlinePreference) ?? .automatic
    }
}

struct ResolvedAppSettings: Equatable {
    var language: TranscriptionLanguage
    var insertionStrategy: InsertionStrategy
    var postProcessing: PostProcessingOptions
    var newlinePreference: NewlinePreference
}

enum AppProfileResolver {
    static func resolve(
        bundleIdentifier: String?,
        profiles: [AppProfile],
        globalLanguage: TranscriptionLanguage,
        globalInsertionStrategy: InsertionStrategy,
        globalPostProcessing: PostProcessingOptions
    ) -> ResolvedAppSettings {
        guard let bundleIdentifier,
              let profile = profiles.first(where: { $0.isEnabled && $0.bundleIdentifier == bundleIdentifier })
        else {
            return ResolvedAppSettings(
                language: globalLanguage,
                insertionStrategy: globalInsertionStrategy,
                postProcessing: globalPostProcessing,
                newlinePreference: .automatic
            )
        }
        return ResolvedAppSettings(
            language: profile.language,
            insertionStrategy: profile.insertionStrategy,
            postProcessing: profile.postProcessing,
            newlinePreference: profile.newlinePreference
        )
    }
}
