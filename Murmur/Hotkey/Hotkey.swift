import Carbon
import CoreGraphics
import CoreServices
import Foundation

/// A push-to-talk hotkey. Two shapes are supported:
///
/// * **Key + modifiers** (`isModifierOnly == false`): a regular key (Space, F13, V…)
///   optionally combined with ⌘⌥⌃⇧/fn. `modifiers` holds only the generic
///   modifier bits, so either the left or the right modifier key qualifies.
/// * **Modifier-only** (`isModifierOnly == true`): one or more modifier keys held
///   on their own (right ⌥, fn, ⌃⌥…). `modifiers` additionally keeps the
///   device-specific left/right bits so "right ⌥" and "left ⌥" are distinct.
///   `keyCode` is the virtual key code of the last modifier pressed while
///   recording the hotkey; it is only used for display.
struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt64
    var isModifierOnly: Bool

    // MARK: Flag masks

    /// Generic, device-independent modifier bits.
    static let modifierMask: UInt64 =
        CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskSecondaryFn.rawValue

    /// Device-specific bits that tell left and right modifier keys apart
    /// (NX_DEVICEL*/NX_DEVICER* masks from IOKit).
    static let deviceMask: UInt64 =
        0x0001 // left control
        | 0x0002 // left shift
        | 0x0004 // right shift
        | 0x0008 // left command
        | 0x0010 // right command
        | 0x0020 // left option
        | 0x0040 // right option
        | 0x2000 // right control

    static let fullMask: UInt64 = modifierMask | deviceMask

    /// Right ⌥ held on its own — a good default because it is rarely used
    /// for typing and sits under the right thumb.
    static let `default` = Hotkey(
        keyCode: UInt16(kVK_RightOption),
        modifiers: CGEventFlags.maskAlternate.rawValue | 0x0040,
        isModifierOnly: true
    )

    static let pasteLastDefault = Hotkey(
        keyCode: UInt16(kVK_ANSI_V),
        modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue,
        isModifierOnly: false
    )

    // MARK: Matching

    /// For modifier-only hotkeys: are exactly the required modifiers held?
    /// Every required bit (including the left/right device bit) must be set,
    /// and no *other* generic modifier may be down — so ⌘ + right ⌥ does not
    /// trigger a "right ⌥" hotkey.
    func isModifierChordActive(flags: CGEventFlags) -> Bool {
        let masked = flags.rawValue & Self.fullMask
        guard masked & modifiers == modifiers else { return false }
        return (masked & Self.modifierMask) == (modifiers & Self.modifierMask)
    }

    /// For key hotkeys: does this key-down event match?
    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && (flags.rawValue & Self.modifierMask) == modifiers
    }

    // MARK: Display

    var displayString: String {
        if isModifierOnly {
            return Self.modifierOnlyName(keyCode: keyCode, modifiers: modifiers)
        }
        return Self.modifierSymbols(modifiers) + Self.keyName(for: keyCode)
    }

    static func modifierSymbols(_ modifiers: UInt64) -> String {
        var s = ""
        if modifiers & CGEventFlags.maskSecondaryFn.rawValue != 0 { s += "fn " }
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        return s
    }

    private static func modifierOnlyName(keyCode: UInt16, modifiers: UInt64) -> String {
        var parts: [String] = []
        if modifiers & CGEventFlags.maskSecondaryFn.rawValue != 0 { parts.append("fn") }
        if modifiers & CGEventFlags.maskControl.rawValue != 0 {
            parts.append(side(left: 0x0001, right: 0x2000, in: modifiers) + "⌃")
        }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 {
            parts.append(side(left: 0x0020, right: 0x0040, in: modifiers) + "⌥")
        }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 {
            parts.append(side(left: 0x0002, right: 0x0004, in: modifiers) + "⇧")
        }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 {
            parts.append(side(left: 0x0008, right: 0x0010, in: modifiers) + "⌘")
        }
        if parts.isEmpty { return keyName(for: keyCode) }
        return parts.joined(separator: " + ")
    }

    private static func side(left: UInt64, right: UInt64, in modifiers: UInt64) -> String {
        let hasLeft = modifiers & left != 0
        let hasRight = modifiers & right != 0
        if hasLeft && !hasRight { return "Left " }
        if hasRight && !hasLeft { return "Right " }
        return ""
    }

    /// Human-readable name for a virtual key code, using the current keyboard
    /// layout for printable keys and a fixed table for everything else.
    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }

        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                base,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Help: "Help",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧",
        kVK_Command: "Left ⌘", kVK_RightCommand: "Right ⌘",
        kVK_Option: "Left ⌥", kVK_RightOption: "Right ⌥",
        kVK_Control: "Left ⌃", kVK_RightControl: "Right ⌃",
        kVK_Shift: "Left ⇧", kVK_RightShift: "Right ⇧",
        kVK_Function: "fn", kVK_CapsLock: "⇪",
    ]

    /// Virtual key codes that are modifier keys.
    static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_RightCommand),
        UInt16(kVK_Option), UInt16(kVK_RightOption),
        UInt16(kVK_Control), UInt16(kVK_RightControl),
        UInt16(kVK_Shift), UInt16(kVK_RightShift),
        UInt16(kVK_Function), UInt16(kVK_CapsLock),
    ]
}
