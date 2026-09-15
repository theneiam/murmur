import AppKit
@testable import Murmur
import XCTest

@MainActor
final class FakeWriter: TextWriting {
    var result: TextWriteResult = .verified
    private(set) var written: [String] = []

    func write(_ text: String, to destination: InsertionDestination?) async -> TextWriteResult {
        written.append(text)
        return result
    }
}

@MainActor
final class FakeDestinationChecker: DestinationChecking {
    var destination: InsertionDestination?
    var matchResults: [Bool] = []

    func capture() -> InsertionDestination? { destination }
    func matches(_ destination: InsertionDestination) -> Bool {
        matchResults.isEmpty ? true : matchResults.removeFirst()
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
        XCTAssertEqual(method.method, .accessibility)
        XCTAssertEqual(ax.written, ["hi "])
        XCTAssertEqual(paste.written, [], "pasteboard untouched when AX delivered")
    }

    func testFallbackStrategyPastesWhenAccessibilityDeclines() async throws {
        ax.result = .rejected
        let method = try await inserter.insert("hi ", strategy: .accessibilityThenPasteboard)
        XCTAssertEqual(method.method, .pasteboard)
        XCTAssertEqual(ax.written, ["hi "])
        XCTAssertEqual(paste.written, ["hi "])
    }

    func testAccessibilityOnlyThrowsInsteadOfPasting() async {
        ax.result = .rejected
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
        XCTAssertEqual(method.method, .pasteboard)
        XCTAssertEqual(ax.written, [])
        XCTAssertEqual(paste.written, ["hi "])
    }

    func testEmptyTextIsANoOp() async throws {
        _ = try await inserter.insert("", strategy: .pasteboardOnly)
        XCTAssertEqual(ax.written, [])
        XCTAssertEqual(paste.written, [])
    }

    func testRejectedPasteIsReportedAsFailure() async {
        paste.result = .rejected
        do {
            _ = try await inserter.insert("hi", strategy: .pasteboardOnly)
            XCTFail("a rejected paste must not count as delivered")
        } catch {}
    }

    func testUnverifiedAccessibilityDoesNotRiskADuplicateFallback() async throws {
        ax.result = .unverified

        let result = try await inserter.insert("hi", strategy: .accessibilityThenPasteboard)

        XCTAssertEqual(result.delivery, .unverified)
        XCTAssertEqual(paste.written, [])
    }

    func testDestinationIsCheckedBeforeTheFirstWriteAndAgainBeforeFallback() async {
        let destinations = FakeDestinationChecker()
        let target = InsertionDestination(processID: 100, bundleIdentifier: "test.editor")
        destinations.destination = target
        destinations.matchResults = [true, false]
        ax.result = .rejected
        inserter = StrategyInserter(accessibility: ax, pasteboard: paste, destinations: destinations)

        do {
            _ = try await inserter.insert("hi", strategy: .accessibilityThenPasteboard, destination: target)
            XCTFail("a changed field must prevent fallback")
        } catch {
            XCTAssertEqual(error as? InsertionError, .destinationChanged)
        }
        XCTAssertEqual(ax.written, ["hi"])
        XCTAssertTrue(paste.written.isEmpty)
    }
}

final class InsertionDestinationTests: XCTestCase {
    func testTargetIdentityRejectsAnotherAppFieldOrSelection() {
        let field = AXUIElementCreateApplication(100)
        let otherField = AXUIElementCreateApplication(101)
        let original = InsertionDestination(
            processID: 100,
            bundleIdentifier: "test.editor",
            element: field,
            selection: CFRange(location: 4, length: 0)
        )

        var changed = original
        changed.processID = 200
        XCTAssertFalse(original.matches(changed))

        changed = original
        changed.element = otherField
        XCTAssertFalse(original.matches(changed))

        changed = original
        changed.selection = CFRange(location: 5, length: 0)
        XCTAssertFalse(original.matches(changed))
        XCTAssertTrue(original.matches(original))
    }
}

final class TemporaryClipboardTests: XCTestCase {
    func testRestoresPriorClipboardWhenNobodyCopiesAfterMurmur() throws {
        let pasteboard = NSPasteboard(name: .init("murmur.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        let temporary = try XCTUnwrap(TemporaryClipboard(text: "dictated", pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
        temporary.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "before")
    }

    func testDoesNotOverwriteSomethingCopiedAfterMurmur() throws {
        let pasteboard = NSPasteboard(name: .init("murmur.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let temporary = try XCTUnwrap(TemporaryClipboard(text: "dictated", pasteboard: pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        temporary.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }
}
