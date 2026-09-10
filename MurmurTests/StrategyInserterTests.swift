@testable import Murmur
import XCTest

@MainActor
final class FakeWriter: TextWriting {
    var result = true
    private(set) var written: [String] = []

    init(result: Bool = true) { self.result = result }

    func write(_ text: String) async -> Bool {
        written.append(text)
        return result
    }
}

@MainActor
final class StrategyInserterTests: XCTestCase {
    private var ax: FakeWriter!
    private var paste: FakeWriter!
    private var inserter: StrategyInserter!

    override func setUp() {
        ax = FakeWriter()
        paste = FakeWriter()
        inserter = StrategyInserter(accessibility: ax, pasteboard: paste)
    }

    func testFallbackStrategyUsesAccessibilityWhenItSucceeds() async throws {
        let method = try await inserter.insert("hi ", strategy: .accessibilityThenPasteboard)
        XCTAssertEqual(method, .accessibility)
        XCTAssertEqual(ax.written, ["hi "])
        XCTAssertEqual(paste.written, [], "pasteboard untouched when AX delivered")
    }

    func testFallbackStrategyPastesWhenAccessibilityDeclines() async throws {
        ax.result = false
        let method = try await inserter.insert("hi ", strategy: .accessibilityThenPasteboard)
        XCTAssertEqual(method, .pasteboard)
        XCTAssertEqual(ax.written, ["hi "])
        XCTAssertEqual(paste.written, ["hi "])
    }

    func testAccessibilityOnlyThrowsInsteadOfPasting() async {
        ax.result = false
        do {
            _ = try await inserter.insert("hi ", strategy: .accessibilityOnly)
            XCTFail("expected InsertionError.accessibilityRejected")
        } catch {
            XCTAssertTrue(error is InsertionError)
        }
        XCTAssertEqual(paste.written, [], "never falls back to the clipboard")
    }

    func testPasteOnlyNeverTouchesAccessibility() async throws {
        let method = try await inserter.insert("hi ", strategy: .pasteboardOnly)
        XCTAssertEqual(method, .pasteboard)
        XCTAssertEqual(ax.written, [])
        XCTAssertEqual(paste.written, ["hi "])
    }

    func testEmptyTextIsANoOp() async throws {
        _ = try await inserter.insert("", strategy: .pasteboardOnly)
        XCTAssertEqual(ax.written, [])
        XCTAssertEqual(paste.written, [])
    }
}
