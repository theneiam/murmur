import AppKit
import ApplicationServices
import Foundation

/// A destination held only for one dictation. Never persisted or logged.
struct InsertionDestination: @unchecked Sendable {
    var processID: Int32
    var bundleIdentifier: String?
    var element: AXUIElement?
    var selection: CFRange?
    var isSingleLineField = false
    var newlinePreference: NewlinePreference = .automatic

    var layoutTarget: InsertionTarget {
        InsertionTarget(
            bundleIdentifier: bundleIdentifier,
            isSingleLineField: isSingleLineField,
            newlinePreference: newlinePreference
        )
    }

    /// Compares the app, focused element and caret/selection captured for one
    /// dictation. Missing AX detail falls back to the strongest identity that
    /// was available at key-down time.
    func matches(_ current: InsertionDestination) -> Bool {
        guard processID == current.processID else { return false }
        if let element {
            guard let currentElement = current.element, CFEqual(element, currentElement) else { return false }
        }
        if let selection {
            guard let currentSelection = current.selection,
                  selection.location == currentSelection.location,
                  selection.length == currentSelection.length else { return false }
        }
        return true
    }
}

@MainActor
protocol DestinationChecking {
    func capture() -> InsertionDestination?
    func matches(_ destination: InsertionDestination) -> Bool
}

/// Reads identity and selection bounds, never the contents of another app.
@MainActor
struct FrontmostDestination: DestinationChecking {
    func capture() -> InsertionDestination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var destination = InsertionDestination(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
        guard AXIsProcessTrusted() else { return destination }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return destination }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        destination.element = element
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success {
            destination.isSingleLineField = (role as? String) == (kAXTextFieldRole as String)
        }
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
           let selected, CFGetTypeID(selected) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(selected as! AXValue, .cfRange, &range) { destination.selection = range }
        }
        return destination
    }

    func matches(_ destination: InsertionDestination) -> Bool {
        guard let current = capture() else { return false }
        return destination.matches(current)
    }
}
