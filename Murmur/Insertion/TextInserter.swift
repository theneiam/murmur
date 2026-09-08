import Foundation
import os

enum InsertionStrategy: String, CaseIterable, Codable, Identifiable {
    /// Try the Accessibility API; if the focused app does not accept it,
    /// paste instead. Recommended.
    case accessibilityThenPasteboard
    /// Accessibility only. Never touches the clipboard; fails silently in
    /// apps that do not support it.
    case accessibilityOnly
    /// Always paste (⌘V) and restore the previous clipboard afterwards.
    case pasteboardOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibilityThenPasteboard: return "Accessibility, fall back to paste"
        case .accessibilityOnly: return "Accessibility only"
        case .pasteboardOnly: return "Paste (⌘V) only"
        }
    }

    var detail: String {
        switch self {
        case .accessibilityThenPasteboard:
            return "Inserts directly at the caret without using the clipboard; pastes only in apps that don't support it."
        case .accessibilityOnly:
            return "Never touches the clipboard. Some apps (terminals, a few editors) will not receive text."
        case .pasteboardOnly:
            return "Works everywhere. Your previous clipboard contents are restored right after the paste."
        }
    }
}

enum InsertionError: LocalizedError {
    case accessibilityRejected

    var errorDescription: String? {
        "The focused app did not accept text via Accessibility. Switch the insertion method to \"fall back to paste\" in Settings."
    }
}

/// Picks the insertion path according to the configured strategy.
@MainActor
enum TextInserter {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "insert")

    static func insert(_ text: String, strategy: InsertionStrategy) async throws {
        guard !text.isEmpty else { return }

        switch strategy {
        case .accessibilityThenPasteboard:
            if await insertViaAccessibility(text) {
                log.debug("Inserted via Accessibility")
            } else {
                log.debug("Accessibility declined; pasting")
                await PasteboardInserter.insert(text)
            }
        case .accessibilityOnly:
            guard await insertViaAccessibility(text) else { throw InsertionError.accessibilityRejected }
        case .pasteboardOnly:
            await PasteboardInserter.insert(text)
        }
    }

    /// Every AX call is synchronous IPC into the target app (up to 0.5 s each
    /// with our timeout), so run them off the main thread. The AX API is
    /// thread-safe and does not need a run loop for one-shot calls.
    private static func insertViaAccessibility(_ text: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            AccessibilityInserter.insert(text)
        }.value
    }
}
