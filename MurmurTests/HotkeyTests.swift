import XCTest
import Carbon.HIToolbox
import CoreGraphics
@testable import Murmur

final class HotkeyTests: XCTestCase {
    private let rightOption: UInt64 = 0x0040
    private let leftOption: UInt64 = 0x0020
    private let leftControl: UInt64 = 0x0001
    private let alt = CGEventFlags.maskAlternate.rawValue
    private let cmd = CGEventFlags.maskCommand.rawValue
    private let shift = CGEventFlags.maskShift.rawValue
    private let ctrl = CGEventFlags.maskControl.rawValue
    private let capsLock = CGEventFlags.maskAlphaShift.rawValue

    // MARK: Modifier-only

    func testDefaultIsRightOptionOnly() {
        let hotkey = Hotkey.default
        XCTAssertTrue(hotkey.isModifierOnly)
        XCTAssertEqual(hotkey.keyCode, UInt16(kVK_RightOption))
        XCTAssertEqual(hotkey.displayString, "Right ⌥")
    }

    func testModifierChordMatchesExactSide() {
        let hotkey = Hotkey.default
        XCTAssertTrue(hotkey.isModifierChordActive(flags: CGEventFlags(rawValue: alt | rightOption)))
        XCTAssertFalse(hotkey.isModifierChordActive(flags: CGEventFlags(rawValue: alt | leftOption)), "left ⌥ must not trigger a right ⌥ hotkey")
        XCTAssertFalse(hotkey.isModifierChordActive(flags: CGEventFlags(rawValue: 0)))
    }

    func testModifierChordRejectsExtraGenericModifiers() {
        let hotkey = Hotkey.default
        XCTAssertFalse(hotkey.isModifierChordActive(flags: CGEventFlags(rawValue: alt | rightOption | cmd)), "⌘ + right ⌥ is a shortcut, not the hotkey")
    }

    func testModifierChordIgnoresCapsLockAndOtherStateBits() {
        let hotkey = Hotkey.default
        XCTAssertTrue(hotkey.isModifierChordActive(flags: CGEventFlags(rawValue: alt | rightOption | capsLock)))
        XCTAssertTrue(hotkey.isModifierChordActive(flags: CGEventFlags(rawValue: alt | rightOption | CGEventFlags.maskNonCoalesced.rawValue)))
    }

    func testModifierChordDisplayNames() {
        let fnOnly = Hotkey(keyCode: UInt16(kVK_Function), modifiers: CGEventFlags.maskSecondaryFn.rawValue, isModifierOnly: true)
        XCTAssertEqual(fnOnly.displayString, "fn")

        let chord = Hotkey(keyCode: UInt16(kVK_RightOption), modifiers: ctrl | leftControl | alt | rightOption, isModifierOnly: true)
        XCTAssertEqual(chord.displayString, "Left ⌃ + Right ⌥")

        // Both sides of a modifier held → side prefix omitted.
        let both = Hotkey(keyCode: UInt16(kVK_Option), modifiers: alt | leftOption | rightOption, isModifierOnly: true)
        XCTAssertEqual(both.displayString, "⌥")
    }

    // MARK: Key + modifiers

    func testKeyHotkeyMatchesKeyCodeAndGenericModifiers() {
        let optionSpace = Hotkey(keyCode: UInt16(kVK_Space), modifiers: alt, isModifierOnly: false)
        XCTAssertTrue(optionSpace.matches(keyCode: UInt16(kVK_Space), flags: CGEventFlags(rawValue: alt)))
        XCTAssertTrue(optionSpace.matches(keyCode: UInt16(kVK_Space), flags: CGEventFlags(rawValue: alt | leftOption)), "either ⌥ key qualifies")
        XCTAssertTrue(optionSpace.matches(keyCode: UInt16(kVK_Space), flags: CGEventFlags(rawValue: alt | capsLock)))
        XCTAssertFalse(optionSpace.matches(keyCode: UInt16(kVK_Space), flags: CGEventFlags(rawValue: alt | shift)))
        XCTAssertFalse(optionSpace.matches(keyCode: UInt16(kVK_Space), flags: CGEventFlags(rawValue: 0)))
        XCTAssertFalse(optionSpace.matches(keyCode: UInt16(kVK_ANSI_V), flags: CGEventFlags(rawValue: alt)))
    }

    func testKeyHotkeyDisplayOrdersModifiersLikeMacOS() {
        let hotkey = Hotkey(keyCode: UInt16(kVK_F13), modifiers: cmd | shift | ctrl, isModifierOnly: false)
        XCTAssertEqual(hotkey.displayString, "⌃⇧⌘F13")
        let plain = Hotkey(keyCode: UInt16(kVK_Space), modifiers: 0, isModifierOnly: false)
        XCTAssertEqual(plain.displayString, "Space")
    }

    func testKeyNameFallsBackForUnknownCodes() {
        XCTAssertEqual(Hotkey.keyName(for: UInt16(kVK_F19)), "F19")
        XCTAssertFalse(Hotkey.keyName(for: UInt16(kVK_ANSI_A)).isEmpty)
    }

    // MARK: Codable

    func testRoundTripsThroughJSON() throws {
        let original = Hotkey(keyCode: 12, modifiers: alt | cmd, isModifierOnly: false)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Hotkey.self, from: data), original)
    }
}
