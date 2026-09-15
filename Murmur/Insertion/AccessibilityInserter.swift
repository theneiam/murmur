import ApplicationServices
import Foundation
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
    private static let log = Logger.murmur("ax-insert")

    /// Writes only to the captured element, after the caller validates focus.
    static func insert(_ text: String, into destination: InsertionDestination) -> TextWriteResult {
        guard AXIsProcessTrusted(), let element = destination.element else { return .rejected }
        AXUIElementSetMessagingTimeout(element, 0.3)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else {
            log.debug("Focused element does not accept selected-text writes")
            return .rejected
        }

        let rangeBefore = selectedRange(of: element)
        // Reading the full value can be expensive in large documents, so only
        // do it when the caret position is unavailable for verification.
        let valueBefore = rangeBefore == nil ? stringValue(of: element) : nil

        let setErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard setErr == .success else {
            log.debug("Setting selected text failed (\(setErr.rawValue, privacy: .public))")
            return .rejected
        }

        // Verification: prefer the caret position, then the field contents.
        if let before = rangeBefore, let after = selectedRange(of: element) {
            let expectedLocation = before.location + text.utf16.count
            if after.location == expectedLocation { return .verified }
            if after.location > before.location || after.length != before.length {
                // Caret moved — good enough for editors that normalise text.
                return .verified
            }
            log.debug("Selected-text write was accepted but the caret did not move")
            return .rejected
        }

        if let before = valueBefore, let afterValue = stringValue(of: element) {
            // Any change counts: editors that normalise input (smart quotes,
            // auto-format) may not contain `text` verbatim.
            if afterValue != before { return .verified }
            log.debug("Selected-text write was accepted but value is unchanged")
            return .rejected
        }

        // The write may have worked. Falling back here can duplicate the text.
        log.debug("AX accepted the write but delivery could not be verified")
        return .unverified
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
