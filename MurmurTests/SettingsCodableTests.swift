import XCTest
@testable import Murmur

final class SettingsCodableTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testPostProcessingOptionsDecodeFromEmptyObjectWithDefaults() throws {
        let options = try decode(PostProcessingOptions.self, "{}")
        XCTAssertEqual(options, PostProcessingOptions())
        XCTAssertEqual(options.fillerWords, PostProcessingOptions.defaultFillerWords)
    }

    func testPostProcessingOptionsKeepDefaultsForMissingFields() throws {
        let options = try decode(PostProcessingOptions.self, #"{"autoCapitalize": false, "unknownFutureField": 1}"#)
        XCTAssertFalse(options.autoCapitalize)
        XCTAssertTrue(options.appendTrailingSpace)
        XCTAssertFalse(options.stripFillerWords)
        XCTAssertEqual(options.replacements, [])
    }

    func testReplacementDecodesWithoutIdOrCaseFlag() throws {
        let replacement = try decode(Replacement.self, #"{"find": "a", "replace": "b"}"#)
        XCTAssertEqual(replacement.find, "a")
        XCTAssertEqual(replacement.replace, "b")
        XCTAssertFalse(replacement.caseSensitive)
    }

    func testPostProcessingOptionsRoundTrip() throws {
        var options = PostProcessingOptions()
        options.stripFillerWords = true
        options.replacements = [Replacement(find: "x", replace: "y", caseSensitive: true)]
        options.fillerWords = ["like"]
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(PostProcessingOptions.self, from: data), options)
    }

    // MARK: SettingsStore

    private func freshDefaults() -> UserDefaults {
        let suite = "com.yevhen.murmur.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    func testSettingsStoreStartsWithDefaults() {
        let store = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(store.hotkey, .default)
        XCTAssertEqual(store.model, .largeV3Turbo)
        XCTAssertEqual(store.language, .auto)
        XCTAssertEqual(store.insertionStrategy, .accessibilityThenPasteboard)
        XCTAssertEqual(store.maxRecordingSeconds, 120)
        XCTAssertNil(store.inputDeviceUID)
        XCTAssertTrue(store.playSounds)
        XCTAssertFalse(store.hasCompletedOnboarding)
    }

    @MainActor
    func testSettingsStorePersistsAcrossInstances() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.model = .small
        store.language = .russian
        store.inputDeviceUID = "BuiltInMic"
        store.maxRecordingSeconds = 45
        store.hasCompletedOnboarding = true
        store.postProcessing.replacements = [Replacement(find: "a", replace: "b")]

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.model, .small)
        XCTAssertEqual(reloaded.language, .russian)
        XCTAssertEqual(reloaded.inputDeviceUID, "BuiltInMic")
        XCTAssertEqual(reloaded.maxRecordingSeconds, 45)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
        XCTAssertEqual(reloaded.postProcessing.replacements.map(\.find), ["a"])
    }

    @MainActor
    func testSettingsStoreFallsBackWhenStoredValueIsUnreadable() {
        let defaults = freshDefaults()
        // A model variant that was removed from the catalog, and garbage bytes.
        defaults.set(Data(#""openai_whisper-removed""#.utf8), forKey: "murmur.model")
        defaults.set(Data("not json".utf8), forKey: "murmur.hotkey")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.model, .largeV3Turbo)
        XCTAssertEqual(store.hotkey, .default)
    }
}
