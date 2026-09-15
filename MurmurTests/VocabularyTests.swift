@testable import Murmur
import XCTest

final class VocabularyTests: XCTestCase {
    func testVocabularyRoundTripRetainsUserTextAndIdentity() throws {
        let library = VocabularyLibrary(
            replacements: [Replacement(find: "not alone", replace: "NotAlone")],
            snippets: [VoiceSnippet(trigger: "my signature", expansion: "jane doe\n  Engineer")]
        )
        XCTAssertEqual(try VocabularyLibrary.decode(library.encoded()), library)
    }

    func testImportRejectsUnsupportedVersionsUnknownFieldsAndIncompleteRows() throws {
        let source = try VocabularyLibrary(replacements: [Replacement(find: "murmur", replace: "Murmur")]).encoded()
        var object = try JSONSerialization.jsonObject(with: source) as! [String: Any]
        object["version"] = 2
        XCTAssertThrowsError(try VocabularyLibrary.decode(JSONSerialization.data(withJSONObject: object)))
        object["version"] = 1
        object["unexpected"] = true
        XCTAssertThrowsError(try VocabularyLibrary.decode(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "unexpected")
        object["replacements"] = [["find": "murmur"]]
        XCTAssertThrowsError(try VocabularyLibrary.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testLibraryRejectsConflictingTriggersAndEmptyEntriesBeforeExport() {
        let libraries = [
            VocabularyLibrary(replacements: [Replacement(find: "name", replace: "A"), Replacement(find: "NAME", replace: "B")]),
            VocabularyLibrary(replacements: [Replacement(find: "my signature", replace: "A")], snippets: [VoiceSnippet(trigger: "my signature", expansion: "B")]),
            VocabularyLibrary(replacements: [Replacement(find: " ", replace: "A")]),
            VocabularyLibrary(snippets: [VoiceSnippet(trigger: "signature", expansion: "")]),
            VocabularyLibrary(snippets: [VoiceSnippet(trigger: "new line", expansion: "A")]),
            VocabularyLibrary(snippets: [VoiceSnippet(trigger: "insert comma", expansion: "A")]),
        ]
        for library in libraries { XCTAssertThrowsError(try library.encoded()) }
    }

    func testImportRejectsNullFieldsInsteadOfSilentlyDefaultingThem() throws {
        let source = try VocabularyLibrary(replacements: [Replacement(find: "murmur", replace: "Murmur")]).encoded()
        for field in ["id", "find", "replace", "caseSensitive"] {
            var object = try JSONSerialization.jsonObject(with: source) as! [String: Any]
            var rows = object["replacements"] as! [[String: Any]]
            rows[0][field] = NSNull()
            object["replacements"] = rows
            XCTAssertThrowsError(try VocabularyLibrary.decode(JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testSavingCorrectionValidatesWithoutMutatingExistingLibrary() throws {
        let original = VocabularyLibrary(replacements: [Replacement(find: "murmur", replace: "Murmur")])
        XCTAssertThrowsError(try original.addingCorrection(heard: "Murmur", corrected: "Other"))
        XCTAssertEqual(original.replacements.count, 1)
        let updated = try original.addingCorrection(heard: " not alone ", corrected: "NotAlone")
        XCTAssertEqual(updated.replacements.last?.find, "not alone")
        XCTAssertEqual(original.replacements.count, 1)
    }
}
