@testable import Murmur
import XCTest

final class DiagnosticsReportTests: XCTestCase {
    func testDestinationIsOnTheDesktopWithATimestamp() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let url = DiagnosticsReport.destination(now: date)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Murmur Diagnostics 20"))
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertTrue(url.deletingLastPathComponent().path.hasSuffix("/Desktop") || url.deletingLastPathComponent().path == NSHomeDirectory())
    }
}
