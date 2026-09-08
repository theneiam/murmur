import XCTest
@testable import Murmur

final class TextPostProcessorTests: XCTestCase {
    private var options = PostProcessingOptions()

    override func setUp() {
        options = PostProcessingOptions()
        options.appendTrailingSpace = false
    }

    func testEmptyAndWhitespaceInputProducesEmptyOutput() {
        XCTAssertEqual(TextPostProcessor.process("", options: options), "")
        XCTAssertEqual(TextPostProcessor.process("   \n ", options: options), "")
    }

    func testCapitalizesSentenceStarts() {
        XCTAssertEqual(
            TextPostProcessor.process("hello world. this is a test! really? yes", options: options),
            "Hello world. This is a test! Really? Yes"
        )
    }

    func testCapitalizationHandlesCyrillicAndLeadingDigits() {
        XCTAssertEqual(TextPostProcessor.process("привет. как дела", options: options), "Привет. Как дела")
        XCTAssertEqual(TextPostProcessor.process("3 apples. then more", options: options), "3 apples. Then more")
    }

    func testCapitalizationCanBeDisabled() {
        options.autoCapitalize = false
        XCTAssertEqual(TextPostProcessor.process("hello. world", options: options), "hello. world")
    }

    func testTrailingSpaceIsAppendedOnlyWhenEnabled() {
        options.appendTrailingSpace = true
        XCTAssertEqual(TextPostProcessor.process("hello", options: options), "Hello ")
        XCTAssertEqual(TextPostProcessor.process("   ", options: options), "")
    }

    func testTidiesWhitespaceAroundPunctuation() {
        XCTAssertEqual(TextPostProcessor.process("hello ,  world   !", options: options), "Hello, world!")
        XCTAssertEqual(TextPostProcessor.process("line one\n\nline two", options: options), "Line one line two")
    }

    func testStripsFillerWordsAsWholeWords() {
        options.stripFillerWords = true
        XCTAssertEqual(TextPostProcessor.process("um, hello uh world", options: options), "Hello world")
        XCTAssertEqual(TextPostProcessor.process("Um so, эм, привет", options: options), "So, привет")
        // Fillers inside words are left alone.
        XCTAssertEqual(TextPostProcessor.process("summer humming", options: options), "Summer humming")
    }

    func testFillerStrippingIsOffByDefault() {
        XCTAssertEqual(TextPostProcessor.process("um hello", options: options), "Um hello")
    }

    func testReplacementsMatchWholeWordsCaseInsensitively() {
        options.replacements = [Replacement(find: "not alone", replace: "NotAlone")]
        XCTAssertEqual(TextPostProcessor.process("open the Not Alone app", options: options), "Open the NotAlone app")
        options.replacements = [Replacement(find: "cat", replace: "dog")]
        XCTAssertEqual(TextPostProcessor.process("concatenate the cat", options: options), "Concatenate the dog")
    }

    func testCaseSensitiveReplacementRespectsCase() {
        options.replacements = [Replacement(find: "swift", replace: "Swift", caseSensitive: true)]
        XCTAssertEqual(TextPostProcessor.process("swift and SWIFT", options: options), "Swift and SWIFT")
    }

    func testReplacementTemplateCharactersAreLiteral() {
        options.replacements = [Replacement(find: "price", replace: "$5")]
        XCTAssertEqual(TextPostProcessor.process("the price", options: options), "The $5")
    }

    func testEmptyFindIsIgnored() {
        options.replacements = [Replacement(find: "", replace: "x")]
        XCTAssertEqual(TextPostProcessor.process("hello", options: options), "Hello")
    }
}
