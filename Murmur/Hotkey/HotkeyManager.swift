import Foundation
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox
import os

enum HotkeyError: LocalizedError {
    case accessibilityNotGranted
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission is required to listen for the push-to-talk key."
        case .tapCreationFailed:
            return "Could not install the global keyboard listener."
        }
    }
}

/// Listens for the push-to-talk hotkey system-wide using a CGEvent tap.
///
/// The tap is *active* (`.defaultTap`) so that a key-based hotkey can be
/// swallowed and does not also type into the focused app. Modifier-only
/// hotkeys are never swallowed. The same tap is reused to record a new
/// hotkey from the settings window (`beginCapture`).
@MainActor
final class HotkeyManager {
    /// Marker placed in `eventSourceUserData` on events Murmur posts itself
    /// (the ⌘V used by the pasteboard inserter) so the tap ignores them.
    nonisolated static let syntheticEventTag: Int64 = 0x4D75726D // "Murm"

    var hotkey: Hotkey {
        didSet { if hotkey != oldValue { resetState() } }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Modifier-only hotkeys: fired when another key is typed while the
    /// modifier is held (the user is using a shortcut, not dictating).
    var onCancel: (() -> Void)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var cancelled = false

    private var capture: CaptureSession?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "hotkey")

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    // MARK: Lifecycle

    func start() throws {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { throw HotkeyError.accessibilityNotGranted }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyManager.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true
        log.info("Event tap installed")
    }

    func stop() {
        guard isRunning else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
        resetState()
    }

    /// Drops any in-progress press. A press interrupted this way (hotkey
    /// changed, listener stopped) is cancelled, never treated as a release.
    private func resetState() {
        if isDown, !cancelled { onCancel?() }
        isDown = false
        cancelled = false
    }

    // MARK: Hotkey capture (settings UI)

    private struct CaptureSession {
        var accumulatedFlags: UInt64 = 0
        var lastModifierKeyCode: UInt16 = 0
        var sawModifier = false
        let completion: (Hotkey?) -> Void
    }

    /// Records the next key or modifier chord the user presses. Push-to-talk
    /// is suspended while capturing. Escape cancels (`completion(nil)`).
    func beginCapture(_ completion: @escaping (Hotkey?) -> Void) {
        resetState()
        capture = CaptureSession(completion: completion)
    }

    func cancelCapture() {
        let session = capture
        capture = nil
        session?.completion(nil)
    }

    var isCapturing: Bool { capture != nil }

    // MARK: Event handling

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        // The run loop source is attached to the main run loop, so the callback
        // always arrives on the main thread. `assumeIsolated` requires a
        // Sendable result, hence the Bool round-trip.
        let swallow = MainActor.assumeIsolated {
            manager.handle(type: type, event: event) == nil
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.warning("Event tap was disabled by the system; re-enabled")
            return passthrough
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return passthrough
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
            return passthrough
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if capture != nil {
            return handleCapture(type: type, keyCode: keyCode, flags: flags) ? nil : passthrough
        }

        if hotkey.isModifierOnly {
            handleModifierOnly(type: type, keyCode: keyCode, flags: flags)
            return passthrough
        }

        return handleKeyHotkey(type: type, keyCode: keyCode, flags: flags, event: event) ? nil : passthrough
    }

    /// Returns `true` when the event should be swallowed.
    private func handleKeyHotkey(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, event: CGEvent) -> Bool {
        switch type {
        case .keyDown:
            if !isDown {
                guard hotkey.matches(keyCode: keyCode, flags: flags) else { return false }
                isDown = true
                cancelled = false
                onPress?()
                return true
            }
            // Auto-repeat (or modifier drift) while held: keep swallowing.
            return keyCode == hotkey.keyCode
        case .keyUp:
            guard isDown, keyCode == hotkey.keyCode else { return false }
            isDown = false
            onRelease?()
            return true
        default:
            return false
        }
    }

    private func handleModifierOnly(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        switch type {
        case .flagsChanged:
            let active = hotkey.isModifierChordActive(flags: flags)
            if active, !isDown {
                isDown = true
                cancelled = false
                onPress?()
            } else if !active, isDown {
                isDown = false
                if !cancelled { onRelease?() }
                cancelled = false
            }
        case .keyDown:
            // A real key was typed while the modifier is held: the user is
            // invoking a shortcut (e.g. ⌥ + letter), not dictating.
            if isDown, !cancelled, !Hotkey.modifierKeyCodes.contains(keyCode) {
                cancelled = true
                onCancel?()
            }
        default:
            break
        }
    }

    /// Returns `true` when the event should be swallowed.
    private func handleCapture(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard var session = capture else { return false }

        switch type {
        case .flagsChanged:
            let masked = flags.rawValue & Hotkey.fullMask
            if masked != 0 {
                session.accumulatedFlags |= masked
                session.lastModifierKeyCode = keyCode
                session.sawModifier = true
                capture = session
            } else if session.sawModifier {
                // Every modifier released without a key: modifier-only hotkey.
                let result = Hotkey(
                    keyCode: session.lastModifierKeyCode,
                    modifiers: session.accumulatedFlags,
                    isModifierOnly: true
                )
                finishCapture(with: result)
            }
            return false

        case .keyDown:
            if keyCode == UInt16(kVK_Escape), flags.rawValue & Hotkey.modifierMask == 0 {
                finishCapture(with: nil)
                return true
            }
            if Hotkey.modifierKeyCodes.contains(keyCode) { return true }
            let result = Hotkey(
                keyCode: keyCode,
                modifiers: flags.rawValue & Hotkey.modifierMask,
                isModifierOnly: false
            )
            finishCapture(with: result)
            return true

        case .keyUp:
            return true

        default:
            return false
        }
    }

    private func finishCapture(with hotkey: Hotkey?) {
        let session = capture
        capture = nil
        session?.completion(hotkey)
    }
}
