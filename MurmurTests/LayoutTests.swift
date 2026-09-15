@testable import Murmur
import XCTest

// MARK: - Spoken layout commands and newline survival

final class SpokenLayoutTests: XCTestCase {
    private var options = PostProcessingOptions()

    override func setUp() {
        options = PostProcessingOptions()
        options.appendTrailingSpace = false
    }

    // Newlines must survive post-processing at all — today tidyWhitespace eats them.

    func testExistingNewlinesSurvivePostProcessing() {
        let out = TextPostProcessor.process("first line\nsecond line", options: options)
        XCTAssertEqual(out, "First line\nSecond line")
    }

    func testCapitalisationReArmsAfterALineBreak() {
        options.autoCapitalize = true
        let out = TextPostProcessor.process("купить молоко\nпозвонить врачу", options: options)
        XCTAssertEqual(out, "Купить молоко\nПозвонить врачу", "every line starts a new sentence")
    }

    func testHorizontalRunsStillCollapseAndBlankLinesAreCapped() {
        let out = TextPostProcessor.process("one   two\n\n\n\nthree", options: options)
        XCTAssertEqual(out, "One two\n\nThree", "spaces collapse; 3+ blank lines cap at one")
    }

    func testSpaceBeforePunctuationIsStillTidied() {
        XCTAssertEqual(TextPostProcessor.process("hello , world !", options: options), "Hello, world!")
    }

    // The commands themselves.

    func testNewLineCommandBecomesALineBreak() {
        let out = TextPostProcessor.process("buy milk. New line. call the dentist", options: options)
        XCTAssertEqual(out, "Buy milk.\nCall the dentist")
    }

    func testNewParagraphCommandBecomesABlankLine() {
        let out = TextPostProcessor.process("that is the summary. New paragraph. now the details", options: options)
        XCTAssertEqual(out, "That is the summary.\n\nNow the details")
    }

    func testRussianCommandsWork() {
        let line = TextPostProcessor.process("купить молоко. Новая строка. позвонить врачу", options: options)
        XCTAssertEqual(line, "Купить молоко.\nПозвонить врачу")
        let para = TextPostProcessor.process("это итог. Новый абзац. теперь детали", options: options)
        XCTAssertEqual(para, "Это итог.\n\nТеперь детали")
    }

    func testCommandIsRecognisedAfterACommaToo() {
        let out = TextPostProcessor.process("buy milk, new line, call the dentist", options: options)
        XCTAssertEqual(out, "Buy milk,\nCall the dentist")
    }

    func testCommandAtTheStartOrEndDoesNotLeaveStrayBlankLines() {
        XCTAssertEqual(TextPostProcessor.process("New line. hello", options: options), "Hello")
        XCTAssertEqual(TextPostProcessor.process("hello. New line.", options: options), "Hello.")
    }

    // The critical safety property: the phrase mid-clause is CONTENT, not a command.

    func testPhraseInsideAClauseIsLeftAsWords() {
        let out = TextPostProcessor.process("I need a new line of credit", options: options)
        XCTAssertEqual(out, "I need a new line of credit", "not a standalone command — must stay literal")
    }

    func testRussianPhraseInsideAClauseIsLeftAsWords() {
        let out = TextPostProcessor.process("это новая строка кода", options: options)
        XCTAssertEqual(out, "Это новая строка кода")
    }

    func testLiteralLayoutWordsAtClauseBoundariesArePreserved() {
        for input in ["New line of credit is available", "New lines are useful", "Новая строка кода работает", "A new product: new line of laptops"] {
            XCTAssertEqual(TextPostProcessor.process(input, options: options), input)
        }
    }

    func testCommandsCanBeTurnedOff() {
        options.spokenLayout = false
        let out = TextPostProcessor.process("buy milk. New line. call the dentist", options: options)
        XCTAssertEqual(out, "Buy milk. New line. Call the dentist")
    }

    func testSpokenLayoutIsOnByDefault() {
        XCTAssertTrue(PostProcessingOptions().spokenLayout)
    }

    func testOptionsStillDecodeFromAFileWrittenBeforeThisFeature() throws {
        let old = try JSONDecoder().decode(PostProcessingOptions.self, from: Data(#"{"autoCapitalize": true}"#.utf8))
        XCTAssertTrue(old.spokenLayout, "missing field falls back to the default, never wipes settings")
    }

    func testTrailingSpaceStillAppliesAfterAMultiLineResult() {
        options.appendTrailingSpace = true
        let out = TextPostProcessor.process("a. New line. b", options: options)
        XCTAssertEqual(out, "A.\nB ")
    }
}

// MARK: - Target-aware newline flattening

final class LayoutPolicyTests: XCTestCase {
    func testMultiLineTextIsUnchangedForAnOrdinaryDocumentTarget() {
        let target = InsertionTarget(bundleIdentifier: "com.apple.Notes", isSingleLineField: false)
        XCTAssertEqual(LayoutPolicy.adapt("a\nb", for: target), "a\nb")
    }

    func testNewlinesAreFlattenedForSendOnReturnApps() {
        for id in ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS", "ru.keepcoder.Telegram"] {
            let target = InsertionTarget(bundleIdentifier: id, isSingleLineField: false)
            XCTAssertEqual(LayoutPolicy.adapt("a\nb", for: target), "a b", "\(id) sends on Return")
        }
    }

    func testNewlinesAreFlattenedForTerminals() {
        let target = InsertionTarget(bundleIdentifier: "com.apple.Terminal", isSingleLineField: false)
        XCTAssertEqual(LayoutPolicy.adapt("rm -rf x\nls", for: target), "rm -rf x ls", "a newline would run the command")
    }

    func testNewlinesAreFlattenedInASingleLineField() {
        let target = InsertionTarget(bundleIdentifier: "com.apple.Safari", isSingleLineField: true)
        XCTAssertEqual(LayoutPolicy.adapt("a\nb", for: target), "a b")
    }

    func testBlankLinesCollapseToASingleSpaceWhenFlattened() {
        let target = InsertionTarget(bundleIdentifier: "com.apple.Terminal", isSingleLineField: false)
        XCTAssertEqual(LayoutPolicy.adapt("a\n\nb", for: target), "a b")
    }

    func testSingleLineTextIsNeverTouched() {
        let target = InsertionTarget(bundleIdentifier: "com.apple.Terminal", isSingleLineField: true)
        XCTAssertEqual(LayoutPolicy.adapt("just words ", for: target), "just words ")
    }

    func testUnknownAppKeepsItsLineBreaks() {
        let target = InsertionTarget(bundleIdentifier: "com.example.SomeEditor", isSingleLineField: false)
        XCTAssertEqual(LayoutPolicy.adapt("a\nb", for: target), "a\nb")
    }

    func testMissingBundleIdentifierKeepsLineBreaks() {
        let target = InsertionTarget(bundleIdentifier: nil, isSingleLineField: false)
        XCTAssertEqual(LayoutPolicy.adapt("a\nb", for: target), "a\nb")
    }
}
