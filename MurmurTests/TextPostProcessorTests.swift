@testable import Murmur
import XCTest

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
    }

    func testLineBreaksArePreservedRatherThanCollapsed() {
        // Changed deliberately when spoken layout landed: a newline that
        // reaches post-processing was put there on purpose. See LayoutTests.
        XCTAssertEqual(TextPostProcessor.process("line one\n\nline two", options: options), "Line one\n\nLine two")
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

    func testVerbatimBypassesAllTextTransformations() {
        options.verbatim = true
        options.stripFillerWords = true
        options.appendTrailingSpace = true
        options.replacements = [Replacement(find: "murmur", replace: "MURMUR")]
        let raw = " um,  murmur. new line. next "
        XCTAssertEqual(TextPostProcessor.process(raw, options: options), raw)
    }

    func testSnippetExpansionPreservesExactCasingSpacingAndLineBreaks() {
        options.snippets = [VoiceSnippet(trigger: "my signature", expansion: "eBay engineer\n  jane doe")]
        options.replacements = [Replacement(find: "engineer", replace: "DEVELOPER")]
        XCTAssertEqual(TextPostProcessor.process("my signature", options: options), "eBay engineer\n  jane doe")
        XCTAssertEqual(TextPostProcessor.process("use my signature today", options: options), "Use eBay engineer\n  jane doe today")
        XCTAssertEqual(TextPostProcessor.process("my signatures", options: options), "My signatures")
        XCTAssertEqual(TextPostProcessor.process("my signature2", options: options), "My signature2")
    }

    func testExplicitPunctuationCommandsAreOptInAndStandalone() {
        let input = "hello. Insert comma. world"
        XCTAssertEqual(TextPostProcessor.process(input, options: options), "Hello. Insert comma. World")
        options.spokenPunctuation = true
        XCTAssertEqual(TextPostProcessor.process(input, options: options), "Hello, world")
        XCTAssertEqual(TextPostProcessor.process("ready. insert question mark.", options: options), "Ready?")
        XCTAssertEqual(TextPostProcessor.process("insert at sign", options: options), "@")
        XCTAssertEqual(TextPostProcessor.process("Insert commas here", options: options), "Insert commas here")
        XCTAssertEqual(TextPostProcessor.process("Please insert comma in the text", options: options), "Please insert comma in the text")
    }

    func testPunctuationCommandsComposeWithNewlinesAndOtherCommands() {
        options.spokenPunctuation = true
        XCTAssertEqual(TextPostProcessor.process("first\ninsert hash sign. second", options: options), "First\n# Second")
        XCTAssertEqual(TextPostProcessor.process("hello. insert comma. insert ampersand. world", options: options), "Hello,& world")
    }

    func testNewTextOptionsDecodeTolerantlyAndVerbatimBypassesSnippets() throws {
        let old = try JSONDecoder().decode(PostProcessingOptions.self, from: Data("{}".utf8))
        XCTAssertFalse(old.verbatim)
        XCTAssertFalse(old.spokenPunctuation)
        XCTAssertTrue(old.snippets.isEmpty)
        options.verbatim = true
        options.snippets = [VoiceSnippet(trigger: "signature", expansion: "Jane")]
        options.spokenPunctuation = true
        XCTAssertEqual(TextPostProcessor.process("signature. insert comma.", options: options), "signature. insert comma.")
    }
}
