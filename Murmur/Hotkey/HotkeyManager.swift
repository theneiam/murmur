import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
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

/// The push-to-talk state machine driven by raw tap events. A value type
/// with no side effects: `handle` returns whether to swallow the event and
/// which high-level events to deliver, so it can be unit-tested and so the
/// tap callback only ever does a few integer comparisons.
struct TapState: Equatable {
    enum Event: Equatable {
        case press
        case release
        /// Modifier-only hotkeys: another key was typed while the modifier was
        /// held (the user is using a shortcut, not dictating).
        case cancel
        case captured(Hotkey?)
    }

    struct Capture: Equatable {
        var accumulatedFlags: UInt64 = 0
        var lastModifierKeyCode: UInt16 = 0
        var sawModifier = false
    }

    var hotkey: Hotkey
    var isDown = false
    var cancelled = false
    var capture: Capture?

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    var isCapturing: Bool { capture != nil }

    /// Drops any in-progress press. A press interrupted this way (hotkey
    /// changed, listener stopped) is cancelled, never treated as a release.
    mutating func reset() -> [Event] {
        let events: [Event] = isDown && !cancelled ? [.cancel] : []
        isDown = false
        cancelled = false
        return events
    }

    mutating func setHotkey(_ new: Hotkey) -> [Event] {
        guard new != hotkey else { return [] }
        hotkey = new
        return reset()
    }

    mutating func beginCapture() -> [Event] {
        let events = reset()
        capture = Capture()
        return events
    }

    mutating func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> (swallow: Bool, events: [Event]) {
        if capture != nil {
            return handleCapture(type: type, keyCode: keyCode, flags: flags)
        }
        if hotkey.isModifierOnly {
            return (false, handleModifierOnly(type: type, keyCode: keyCode, flags: flags))
        }
        return handleKeyHotkey(type: type, keyCode: keyCode, flags: flags)
    }

    private mutating func handleKeyHotkey(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> (swallow: Bool, events: [Event]) {
        switch type {
        case .keyDown:
            if !isDown {
                guard hotkey.matches(keyCode: keyCode, flags: flags) else { return (false, []) }
                isDown = true
                cancelled = false
                return (true, [.press])
            }
            // Auto-repeat (or modifier drift) while held: keep swallowing.
            return (keyCode == hotkey.keyCode, [])
        case .keyUp:
            guard isDown, keyCode == hotkey.keyCode else { return (false, []) }
            isDown = false
            return (true, [.release])
        default:
            return (false, [])
        }
    }

    private mutating func handleModifierOnly(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> [Event] {
        switch type {
        case .flagsChanged:
            let active = hotkey.isModifierChordActive(flags: flags)
            if active, !isDown {
                isDown = true
                cancelled = false
                return [.press]
            } else if !active, isDown {
                isDown = false
                let wasCancelled = cancelled
                cancelled = false
                return wasCancelled ? [] : [.release]
            }
            return []
        case .keyDown:
            if isDown, !cancelled, !Hotkey.modifierKeyCodes.contains(keyCode) {
                cancelled = true
                return [.cancel]
            }
            return []
        default:
            return []
        }
    }

    private mutating func handleCapture(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> (swallow: Bool, events: [Event]) {
        guard var session = capture else { return (false, []) }

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
                capture = nil
                return (false, [.captured(Hotkey(
                    keyCode: session.lastModifierKeyCode,
                    modifiers: session.accumulatedFlags,
                    isModifierOnly: true
                ))])
            }
            return (false, [])

        case .keyDown:
            if keyCode == UInt16(kVK_Escape), flags.rawValue & Hotkey.modifierMask == 0 {
                capture = nil
                return (true, [.captured(nil)])
            }
            if Hotkey.modifierKeyCodes.contains(keyCode) { return (true, []) }
            capture = nil
            return (true, [.captured(Hotkey(
                keyCode: keyCode,
                modifiers: flags.rawValue & Hotkey.modifierMask,
                isModifierOnly: false
            ))])

        case .keyUp:
            return (true, [])

        default:
            return (false, [])
        }
    }
}

/// Listens for the push-to-talk hotkey system-wide using a CGEvent tap.
///
/// The tap runs on its own thread with its own run loop, so a busy main
/// thread (audio engine start-up, SwiftUI layout, synchronous AX calls) can
/// never delay the callback — a slow callback stalls every keystroke on the
/// system and eventually gets the tap disabled. The callback touches only
/// `TapState` under a lock and posts the resulting events to the main queue,
/// where `onPress` / `onRelease` / `onCancel` and capture completions run.
///
/// The tap is *active* (`.defaultTap`) so that a key-based hotkey can be
/// swallowed and does not also type into the focused app. Modifier-only
/// hotkeys are never swallowed. The same tap is reused to record a new
/// hotkey from the settings window (`beginCapture`).
///
/// All methods and properties are main-thread only unless noted.
final class HotkeyManager: @unchecked Sendable {
    var hotkey: Hotkey {
        get { state.withLock { $0.hotkey } }
        set { deliver(state.withLock { $0.setHotkey(newValue) }) }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var isRunning = false

    // Shared with the tap thread.
    private let state: OSAllocatedUnfairLock<TapState>
    private let tapPort = OSAllocatedUnfairLock<CFMachPort?>(initialState: nil)

    private var thread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var captureCompletion: ((Hotkey?) -> Void)?
    private let log = Logger.murmur("hotkey")

    init(hotkey: Hotkey) {
        state = OSAllocatedUnfairLock(initialState: TapState(hotkey: hotkey))
    }

    // MARK: Lifecycle

    func start() throws {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { throw HotkeyError.accessibilityNotGranted }

        let ready = DispatchSemaphore(value: 0)
        var created = false
        let thread = Thread { [self] in
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
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            tapPort.withLock { $0 = tap }
            tapRunLoop = CFRunLoopGetCurrent()
            created = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.yevhen.murmur.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Tap creation takes well under a millisecond; block so `start()`
        // can report failure synchronously like before.
        ready.wait()

        guard created else { throw HotkeyError.tapCreationFailed }
        self.thread = thread
        isRunning = true
        log.info("Event tap installed on its own thread")
    }

    func stop() {
        guard isRunning else { return }
        if let tap = tapPort.withLock({ port -> CFMachPort? in defer { port = nil }
            return port }) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapRunLoop { CFRunLoopStop(tapRunLoop) }
        tapRunLoop = nil
        thread = nil
        isRunning = false
        deliver(state.withLock { $0.reset() })
    }

    // MARK: Hotkey capture (settings UI)

    /// Records the next key or modifier chord the user presses. Push-to-talk
    /// is suspended while capturing. Escape cancels (`completion(nil)`).
    func beginCapture(_ completion: @escaping (Hotkey?) -> Void) {
        captureCompletion = completion
        deliver(state.withLock { $0.beginCapture() })
    }

    func cancelCapture() {
        state.withLock { $0.capture = nil }
        let completion = captureCompletion
        captureCompletion = nil
        completion?(nil)
    }

    var isCapturing: Bool { state.withLock { $0.isCapturing } }

    // MARK: Event handling (tap thread)

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        return manager.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    /// Runs on the tap thread. Returns `true` when the event should be
    /// swallowed. Must stay cheap: no allocation-heavy work, no main-actor
    /// state, no logging on the hot path.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tapPort.withLock({ $0 }) { CGEvent.tapEnable(tap: tap, enable: true) }
            log.warning("Event tap was disabled by the system; re-enabled")
            return false
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return false
        }

        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEvents.tag {
            return false
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let (swallow, events) = state.withLock { $0.handle(type: type, keyCode: keyCode, flags: flags) }
        deliver(events)
        return swallow
    }

    // MARK: Delivery (any thread → main)

    private func deliver(_ events: [TapState.Event]) {
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events { dispatch(event) }
        }
    }

    private func dispatch(_ event: TapState.Event) {
        switch event {
        case .press: onPress?()
        case .release: onRelease?()
        case .cancel: onCancel?()
        case let .captured(hotkey):
            let completion = captureCompletion
            captureCompletion = nil
            completion?(hotkey)
        }
    }
}
