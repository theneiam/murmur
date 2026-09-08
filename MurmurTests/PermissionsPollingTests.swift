import XCTest
@testable import Murmur

@MainActor
final class PermissionsPollingTests: XCTestCase {
    func testTimerRunsAtFastestRequestedIntervalAndRelaxesWhenReleased() {
        let permissions = PermissionsManager()
        XCTAssertNil(permissions.pollInterval)

        permissions.startPolling(interval: 2.0)
        XCTAssertEqual(permissions.pollInterval, 2.0)

        permissions.startPolling(interval: 1.0)
        XCTAssertEqual(permissions.pollInterval, 1.0, "onboarding's faster poll wins while active")

        permissions.stopPolling(interval: 1.0)
        XCTAssertEqual(permissions.pollInterval, 2.0, "drops back to the background rate")

        permissions.stopPolling(interval: 2.0)
        XCTAssertNil(permissions.pollInterval)
    }

    func testStoppingAnUnknownIntervalIsHarmless() {
        let permissions = PermissionsManager()
        permissions.startPolling(interval: 2.0)
        permissions.stopPolling(interval: 5.0)
        XCTAssertEqual(permissions.pollInterval, 2.0)
    }
}
