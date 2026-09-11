@testable import Murmur
import XCTest

/// Runs in the app host, so the real SwiftUI app and delegate exist.
@MainActor
final class AppWindowsTests: XCTestCase {
    /// Documents why menu actions must not reach the delegate through
    /// `NSApp.delegate`: SwiftUI installs its own wrapper of the same name.
    func testNSAppDelegateIsNotMurmursAppDelegate() {
        XCTAssertNil(NSApp.delegate as? AppDelegate)
    }

    func testStatisticsWindowOpensFromTheCompositionRoot() async throws {
        AppState.shared.showStatistics()
        try await Task.sleep(for: .milliseconds(300))
        let window = NSApp.windows.first { $0.title == "Murmur Statistics" }
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.isVisible, true)
        window?.close()
    }
}
