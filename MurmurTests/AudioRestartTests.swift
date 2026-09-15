@testable import Murmur
import XCTest

final class AudioRestartTests: XCTestCase {
    func testEveryReplacementEngineMustDeliverItsOwnFirstBuffer() {
        var policy = AudioRestartPolicy(maxRestarts: 3)
        policy.beginCapture()
        let first = policy.beginEngine()
        XCTAssertTrue(policy.acceptBuffer(generation: first))
        XCTAssertFalse(policy.shouldRestartAfterSilence(generation: first))
        let replacement = policy.beginEngine()
        XCTAssertTrue(policy.shouldRestartAfterSilence(generation: replacement))
        XCTAssertFalse(policy.acceptBuffer(generation: first), "late buffers belong to the discarded engine")
        XCTAssertTrue(policy.shouldRestartAfterSilence(generation: replacement))
        XCTAssertTrue(policy.acceptBuffer(generation: replacement))
        XCTAssertFalse(policy.shouldRestartAfterSilence(generation: replacement))
    }
}
