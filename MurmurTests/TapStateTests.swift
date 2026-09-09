import Carbon.HIToolbox
import CoreGraphics
@testable import Murmur
import XCTest

final class TapStateTests: XCTestCase {
    private let rightOption: UInt64 = 0x0040
    private let alt = CGEventFlags.maskAlternate.rawValue
    private let cmd = CGEventFlags.maskCommand.rawValue
    private let none = CGEventFlags(rawValue: 0)

    private var rightOptionDown: CGEventFlags { CGEventFlags(rawValue: alt | rightOption) }

    // MARK: Modifier-only hotkey

    func testModifierPressAndReleaseAreNeverSwallowed() {
        var state = TapState(hotkey: .default)
        let down = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: rightOptionDown)
        XCTAssertFalse(down.swallow)
        XCTAssertEqual(down.events, [.press])

        let up = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: none)
        XCTAssertFalse(up.swallow)
        XCTAssertEqual(up.events, [.release])
    }

    func testTypingWhileModifierHeldCancelsOnceAndSuppressesRelease() {
        var state = TapState(hotkey: .default)
        _ = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: rightOptionDown)

        let typed = state.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_E), flags: rightOptionDown)
        XCTAssertFalse(typed.swallow, "the shortcut must still reach the app")
        XCTAssertEqual(typed.events, [.cancel])

        let typedAgain = state.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_E), flags: rightOptionDown)
        XCTAssertEqual(typedAgain.events, [], "cancel fires once")

        let up = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: none)
        XCTAssertEqual(up.events, [], "no release after a cancel")

        // Next press works normally again.
        let again = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: rightOptionDown)
        XCTAssertEqual(again.events, [.press])
    }

    func testPressingAnotherModifierKeyDoesNotCancel() {
        var state = TapState(hotkey: .default)
        _ = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: rightOptionDown)
        let shiftDown = state.handle(type: .keyDown, keyCode: UInt16(kVK_Shift), flags: rightOptionDown)
        XCTAssertEqual(shiftDown.events, [])
    }

    func testWrongSideModifierIsIgnored() {
        var state = TapState(hotkey: .default)
        let leftDown = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_Option), flags: CGEventFlags(rawValue: alt | 0x0020))
        XCTAssertEqual(leftDown.events, [])
        XCTAssertFalse(state.isDown)
    }

    // MARK: Key hotkey

    func testKeyHotkeyIsSwallowedIncludingAutoRepeat() {
        var state = TapState(hotkey: Hotkey(keyCode: UInt16(kVK_F13), modifiers: 0, isModifierOnly: false))
        let down = state.handle(type: .keyDown, keyCode: UInt16(kVK_F13), flags: none)
        XCTAssertTrue(down.swallow)
        XCTAssertEqual(down.events, [.press])

        let repeated = state.handle(type: .keyDown, keyCode: UInt16(kVK_F13), flags: none)
        XCTAssertTrue(repeated.swallow)
        XCTAssertEqual(repeated.events, [])

        let other = state.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_A), flags: none)
        XCTAssertFalse(other.swallow, "other keys pass through while the hotkey is held")
        XCTAssertEqual(other.events, [])

        let up = state.handle(type: .keyUp, keyCode: UInt16(kVK_F13), flags: none)
        XCTAssertTrue(up.swallow)
        XCTAssertEqual(up.events, [.release])
    }

    func testKeyHotkeyWithWrongModifiersPassesThrough() {
        var state = TapState(hotkey: Hotkey(keyCode: UInt16(kVK_Space), modifiers: alt, isModifierOnly: false))
        let plainSpace = state.handle(type: .keyDown, keyCode: UInt16(kVK_Space), flags: none)
        XCTAssertFalse(plainSpace.swallow)
        XCTAssertEqual(plainSpace.events, [])
        let strayUp = state.handle(type: .keyUp, keyCode: UInt16(kVK_Space), flags: none)
        XCTAssertFalse(strayUp.swallow)
        XCTAssertEqual(strayUp.events, [])
    }

    // MARK: Reset / hotkey change

    func testChangingHotkeyMidPressCancelsInsteadOfReleasing() {
        var state = TapState(hotkey: .default)
        _ = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: rightOptionDown)
        let events = state.setHotkey(Hotkey(keyCode: UInt16(kVK_F13), modifiers: 0, isModifierOnly: false))
        XCTAssertEqual(events, [.cancel])
        XCTAssertFalse(state.isDown)
        XCTAssertEqual(state.setHotkey(state.hotkey), [], "same hotkey is a no-op")
    }

    func testResetWhenIdleEmitsNothing() {
        var state = TapState(hotkey: .default)
        XCTAssertEqual(state.reset(), [])
    }

    // MARK: Capture

    func testCaptureRecordsModifierChordOnFullRelease() {
        var state = TapState(hotkey: .default)
        XCTAssertEqual(state.beginCapture(), [])
        XCTAssertTrue(state.isCapturing)

        let ctrlDown = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_Control), flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0001))
        XCTAssertFalse(ctrlDown.swallow)
        XCTAssertEqual(ctrlDown.events, [])

        let both = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0001 | alt | rightOption)
        _ = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: both)
        // Release ⌃ first: still one modifier down, keep accumulating.
        _ = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_Control), flags: rightOptionDown)
        let done = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: none)

        let expected = Hotkey(keyCode: UInt16(kVK_Control), modifiers: CGEventFlags.maskControl.rawValue | 0x0001 | alt | rightOption, isModifierOnly: true)
        XCTAssertEqual(done.events, [.captured(expected)])
        XCTAssertFalse(state.isCapturing)
    }

    func testCaptureRecordsKeyWithGenericModifiersAndSwallowsIt() {
        var state = TapState(hotkey: .default)
        _ = state.beginCapture()
        let flags = CGEventFlags(rawValue: cmd | 0x0008)
        _ = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_Command), flags: flags)
        let key = state.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_V), flags: flags)
        XCTAssertTrue(key.swallow)
        XCTAssertEqual(key.events, [.captured(Hotkey(keyCode: UInt16(kVK_ANSI_V), modifiers: cmd, isModifierOnly: false))])
        XCTAssertFalse(state.isCapturing)
        // The matching key-up arrives after capture ended and goes to the app.
        XCTAssertFalse(state.handle(type: .keyUp, keyCode: UInt16(kVK_ANSI_V), flags: none).swallow)
    }

    func testEscapeCancelsCapture() {
        var state = TapState(hotkey: .default)
        _ = state.beginCapture()
        let esc = state.handle(type: .keyDown, keyCode: UInt16(kVK_Escape), flags: none)
        XCTAssertTrue(esc.swallow)
        XCTAssertEqual(esc.events, [.captured(nil)])
        XCTAssertFalse(state.isCapturing)
    }

    func testBeginningCaptureMidPressCancelsTheRecording() {
        var state = TapState(hotkey: .default)
        _ = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: rightOptionDown)
        XCTAssertEqual(state.beginCapture(), [.cancel])
        // While capturing, the hotkey itself no longer triggers push-to-talk.
        let up = state.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightOption), flags: none)
        XCTAssertFalse(up.events.contains(.release))
    }
}
