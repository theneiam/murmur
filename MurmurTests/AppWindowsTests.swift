@testable import Murmur
import XCTest

/// Runs in the app host, so the real SwiftUI app and delegate exist.
@MainActor
final class AppWindowsTests: XCTestCase {
    func testHostedTestAppDoesNotPerformGlobalStartup() {
        XCTAssertFalse(AppDelegate.didPerformStartup)
        XCTAssertFalse(AppState.shared.hotkeys.isRunning, "Constructing AppState must not install the global event tap")
    }

    func testHostedTestDetectionRecognizesXcodeInjectionSignals() {
        XCTAssertTrue(AppDelegate.isRunningTests(environment: ["MURMUR_RUNNING_TESTS": "1"], arguments: []))
        XCTAssertTrue(AppDelegate.isRunningTests(environment: ["XCInjectBundleInto": "/tmp/Murmur.app"], arguments: []))
        XCTAssertTrue(AppDelegate.isRunningTests(environment: ["DYLD_INSERT_LIBRARIES": "/tmp/libXCTestBundleInject.dylib"], arguments: []))
        XCTAssertTrue(AppDelegate.isRunningTests(environment: [:], arguments: ["/tmp/MurmurTests.xctest"]))
        XCTAssertFalse(AppDelegate.isRunningTests(environment: [:], arguments: ["/Applications/Murmur.app/Contents/MacOS/Murmur"]))
    }

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
