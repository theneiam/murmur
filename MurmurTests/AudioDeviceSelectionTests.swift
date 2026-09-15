@testable import Murmur
import XCTest

final class AudioDeviceSelectionTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in")
    private let usb = AudioInputDevice(id: 2, uid: "usb", name: "USB")
    private let headset = AudioInputDevice(id: 3, uid: "headset", name: "Headset")

    func testExplicitInputWinsThenConnectedPreferencesThenSystemDefault() {
        let ranked = AudioDevices.rankedInputs(
            explicitUID: "headset", preferredUIDs: ["missing", "usb", "usb"],
            available: [builtIn, usb, headset], defaultDeviceID: builtIn.id
        )
        XCTAssertEqual(ranked.map(\.uid), ["headset", "usb", "built-in"])
    }

    func testDisconnectedPreferenceFallsBackWithoutChangingThePreference() {
        let preferences = ["usb", "built-in"]
        let ranked = AudioDevices.rankedInputs(explicitUID: nil, preferredUIDs: preferences,
                                               available: [builtIn, headset], defaultDeviceID: headset.id)
        XCTAssertEqual(ranked.map(\.uid), ["built-in", "headset"])
        XCTAssertEqual(preferences, ["usb", "built-in"])
    }

    func testMissingDevicesProduceNoCandidate() {
        XCTAssertTrue(AudioDevices.rankedInputs(explicitUID: "missing", preferredUIDs: [],
                                                available: [], defaultDeviceID: nil).isEmpty)
    }
}
