import XCTest
@testable import Murmur

final class RecordingTests: XCTestCase {
    private let minimum: TimeInterval = 0.3

    func testDurationDerivesFromSampleCount() {
        let recording = Recording(samples: [Float](repeating: 0, count: 16_000), wallClockDuration: 1.0)
        XCTAssertEqual(recording.duration, 1.0, accuracy: 0.0001)
    }

    func testBriefTapIsNotAFailure() {
        // Key released before any buffer arrived: a tap, dismissed silently.
        XCTAssertFalse(Recording(samples: [], wallClockDuration: 0.05).isSilentCaptureFailure(minimumUtterance: minimum))
    }

    func testHeldKeyWithNoAudioIsAFailure() {
        // Engine ran for two seconds and the HAL never delivered a buffer.
        XCTAssertTrue(Recording(samples: [], wallClockDuration: 2.0).isSilentCaptureFailure(minimumUtterance: minimum))
    }

    func testAnyAudioIsNotASilentFailure() {
        XCTAssertFalse(Recording(samples: [0.1, 0.2], wallClockDuration: 2.0).isSilentCaptureFailure(minimumUtterance: minimum))
    }

    func testFailureMessageNamesTheDevice() {
        let named = Recording(samples: [], wallClockDuration: 2, deviceName: "AirPods Pro")
        XCTAssertTrue(named.silentCaptureFailureMessage.contains("“AirPods Pro”"))
        let unnamed = Recording(samples: [], wallClockDuration: 2)
        XCTAssertTrue(unnamed.silentCaptureFailureMessage.contains("the microphone"))
    }

    func testBluetoothFlagDefaultsToFalse() {
        XCTAssertFalse(Recording(samples: []).deviceIsBluetooth)
        XCTAssertTrue(Recording(samples: [], deviceIsBluetooth: true).deviceIsBluetooth)
    }
}
