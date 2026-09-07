import Foundation
import ApplicationServices
import os

/// Inserts text into the focused text field of the frontmost app by writing
/// `kAXSelectedTextAttribute`, which replaces the current selection (or,
/// with a collapsed selection, inserts at the caret). The clipboard is never
/// touched.
///
/// Support varies by app: native AppKit/SwiftUI text views, Notes, Mail,
/// Safari and most Chromium/Electron editors honour it; terminals and some
/// custom editors do not. The result is verified after writing so that the
/// caller can fall back to the pasteboard when an app silently ignores it.
struct AccessibilityInserter {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "ax-insert")

    /// Returns `true` only when the text was verifiably inserted.
    static func insert(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        // Every AX call is synchronous IPC into the target app; keep a hung
        // app from freezing Murmur (the default timeout is 6 s per call).
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusErr == .success, let focusedRef else {
            log.debug("No focused UI element (\(focusErr.rawValue, privacy: .public))")
            return false
        }
        // AXUIElement is a CoreFoundation type; the attribute value is one when
        // the copy succeeded, so this force-cast is safe.
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else {
            log.debug("Focused element does not accept selected-text writes")
            return false
        }

        let rangeBefore = selectedRange(of: element)
        // Reading the full value can be expensive in large documents, so only
        // do it when the caret position is unavailable for verification.
        let valueBefore = rangeBefore == nil ? stringValue(of: element) : nil

        let setErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard setErr == .success else {
            log.debug("Setting selected text failed (\(setErr.rawValue, privacy: .public))")
            return false
        }

        // Verification: prefer the caret position, then the field contents.
        if let before = rangeBefore, let after = selectedRange(of: element) {
            let expectedLocation = before.location + text.utf16.count
            if after.location == expectedLocation { return true }
            if after.location > before.location || after.length != before.length {
                // Caret moved — good enough for editors that normalise text.
                return true
            }
            log.debug("Selected-text write was accepted but the caret did not move")
            return false
        }

        if let before = valueBefore, let afterValue = stringValue(of: element) {
            // Any change counts: editors that normalise input (smart quotes,
            // auto-format) may not contain `text` verbatim.
            if afterValue != before { return true }
            log.debug("Selected-text write was accepted but value is unchanged")
            return false
        }

        // Nothing readable to verify against. Some Chromium/Electron web areas
        // report the attribute as settable, return success and insert nothing,
        // so a "trusted" success here silently loses the dictation. Treat it as
        // a rejection and let the caller paste instead; an app that genuinely
        // accepted the write almost always exposes a readable range or value.
        log.debug("Selected-text write was accepted but nothing is readable to verify it; declining")
        return false
    }

    // MARK: Helpers

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        let value = ref as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
              let string = ref as? String
        else { return nil }
        return string
    }
}
