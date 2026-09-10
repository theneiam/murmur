import Foundation
import os

extension Logger {
    /// Murmur's subsystem logger. Categories: app, dictation, hotkey, audio,
    /// models, whisper, insert, ax-insert, paste-insert.
    static func murmur(_ category: String) -> Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: category)
    }
}
