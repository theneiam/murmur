import AppKit
import ApplicationServices
import Foundation

enum NewlinePreference: String, CaseIterable, Codable, Identifiable {
    case automatic
    case preserve
    case flatten

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .preserve: return "Keep line breaks"
        case .flatten: return "Replace line breaks with spaces"
        }
    }
}

/// Where a dictation is about to land. Captured at insertion time, because
/// whether a line break is safe depends entirely on the destination.
struct InsertionTarget: Equatable {
    var bundleIdentifier: String?
    /// The focused element accepts a single line only (an AX text field
    /// rather than a text area), so a newline would be dropped or submit.
    var isSingleLineField: Bool
    var newlinePreference: NewlinePreference = .automatic
}

/// Decides whether line breaks may reach a given target.
///
/// In a chat app a newline sends the message, and in a terminal it runs the
/// command — a three-line dictation would fire three times. Rather than ask
/// the user to remember which apps are safe, Murmur flattens line breaks back
/// to spaces wherever they are known to be destructive and keeps them
/// everywhere else. Unknown apps keep their line breaks: the default assumes
/// a text editor, which is what most targets are.
enum LayoutPolicy {
    /// Apps where Return sends or executes rather than inserting a line.
    static let flattensNewlines: Set<String> = [
        // Chat: Return sends the message.
        "com.tinyspeck.slackmacgap", // Slack
        "com.hnc.Discord", // Discord
        "com.apple.MobileSMS", // Messages
        "ru.keepcoder.Telegram", // Telegram
        "org.telegram.desktop", // Telegram Desktop
        "com.microsoft.teams2", // Microsoft Teams
        "com.facebook.archon", // Messenger
        "net.whatsapp.WhatsApp", // WhatsApp
        // Terminals: Return runs the command.
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    static func flattens(_ target: InsertionTarget) -> Bool {
        if target.isSingleLineField { return true }
        switch target.newlinePreference {
        case .preserve: return false
        case .flatten: return true
        case .automatic: break
        }
        guard let id = target.bundleIdentifier else { return false }
        return flattensNewlines.contains(id)
    }

    /// The text as it should actually be written into `target`.
    static func adapt(_ text: String, for target: InsertionTarget) -> String {
        guard flattens(target), text.contains("\n") else { return text }
        return text.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
    }

    /// Adapts `text` to whatever is frontmost right now. Resolving the target
    /// costs an AX round trip, so it only runs when the text actually has a
    /// line break to protect — which is the rare case.
    @MainActor
    static func adaptToFrontmostTarget(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        return adapt(text, for: currentTarget())
    }

    /// Not unit-tested: it reads live AppKit and Accessibility state. Kept
    /// deliberately thin, with every decision in `adapt`.
    @MainActor
    private static func currentTarget() -> InsertionTarget {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var singleLine = false
        if AXIsProcessTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.3)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused {
                let element = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.3)
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                   let roleName = role as? String {
                    // A text field holds one line; a text area holds many.
                    singleLine = roleName == (kAXTextFieldRole as String)
                }
            }
        }
        return InsertionTarget(bundleIdentifier: bundleID, isSingleLineField: singleLine)
    }
}
