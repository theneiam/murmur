@testable import Murmur
import XCTest

final class AppProfileTests: XCTestCase {
    func testMatchingEnabledProfileOverridesGlobalOutputSettings() {
        var globalText = PostProcessingOptions()
        globalText.autoCapitalize = true
        var appText = globalText
        appText.autoCapitalize = false
        appText.appendTrailingSpace = false
        let profile = AppProfile(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            language: .ukrainian,
            insertionStrategy: .accessibilityOnly,
            postProcessing: appText,
            newlinePreference: .preserve
        )

        let resolved = AppProfileResolver.resolve(
            bundleIdentifier: "com.example.Editor",
            profiles: [profile],
            globalLanguage: .english,
            globalInsertionStrategy: .pasteboardOnly,
            globalPostProcessing: globalText
        )

        XCTAssertEqual(resolved.language, .ukrainian)
        XCTAssertEqual(resolved.insertionStrategy, .accessibilityOnly)
        XCTAssertFalse(resolved.postProcessing.autoCapitalize)
        XCTAssertFalse(resolved.postProcessing.appendTrailingSpace)
        XCTAssertEqual(resolved.newlinePreference, .preserve)
    }

    func testDisabledWrongAppAndMissingBundleUseGlobalSettings() {
        var text = PostProcessingOptions()
        text.spokenLayout = false
        var disabled = AppProfile(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            language: .russian,
            insertionStrategy: .accessibilityOnly,
            postProcessing: PostProcessingOptions(),
            newlinePreference: .flatten
        )
        disabled.isEnabled = false

        for bundleID in ["com.example.Editor", "com.example.Other", nil] as [String?] {
            let resolved = AppProfileResolver.resolve(
                bundleIdentifier: bundleID,
                profiles: [disabled],
                globalLanguage: .french,
                globalInsertionStrategy: .pasteboardOnly,
                globalPostProcessing: text
            )
            XCTAssertEqual(resolved.language, .french)
            XCTAssertEqual(resolved.insertionStrategy, .pasteboardOnly)
            XCTAssertEqual(resolved.postProcessing, text)
            XCTAssertEqual(resolved.newlinePreference, .automatic)
        }
    }

    func testProfileDecodesMissingNewFieldsWithSafeDefaults() throws {
        let json = #"{"id":"56A20A64-E23E-4B75-BE63-FF9A2F7C0D26","bundleIdentifier":"com.example.Editor","displayName":"Editor","language":"en","insertionStrategy":"accessibilityThenPasteboard","postProcessing":{}}"#
        let profile = try JSONDecoder().decode(AppProfile.self, from: Data(json.utf8))

        XCTAssertTrue(profile.isEnabled)
        XCTAssertEqual(profile.newlinePreference, .automatic)
        XCTAssertEqual(profile.postProcessing, PostProcessingOptions())
    }
}

final class AppProfileLayoutTests: XCTestCase {
    func testPreserveOverrideKeepsNewlinesInChatApps() {
        let target = InsertionTarget(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            isSingleLineField: false,
            newlinePreference: .preserve
        )
        XCTAssertEqual(LayoutPolicy.adapt("one\ntwo", for: target), "one\ntwo")
    }

    func testFlattenOverrideFlattensUnknownApps() {
        let target = InsertionTarget(
            bundleIdentifier: "com.example.Editor",
            isSingleLineField: false,
            newlinePreference: .flatten
        )
        XCTAssertEqual(LayoutPolicy.adapt("one\ntwo", for: target), "one two")
    }

    func testSingleLineFieldAlwaysFlattensEvenWhenProfileSaysPreserve() {
        let target = InsertionTarget(
            bundleIdentifier: "com.example.Editor",
            isSingleLineField: true,
            newlinePreference: .preserve
        )
        XCTAssertEqual(LayoutPolicy.adapt("one\ntwo", for: target), "one two")
    }
}
