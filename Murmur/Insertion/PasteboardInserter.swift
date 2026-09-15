import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Fallback insertion: put the text on the general pasteboard, synthesise
/// ⌘V into the frontmost app, then restore whatever was on the pasteboard
/// before. Works with virtually every app, at the cost of briefly touching
/// the clipboard.
enum PasteboardInserter {
    private static let log = Logger.murmur("paste-insert")

    /// How long to wait after ⌘V before restoring the clipboard. Apps read the
    /// pasteboard synchronously while handling the key event, so this only
    /// needs to cover event delivery latency.
    static var restoreDelay: Duration = .milliseconds(250)

    @MainActor
    static func insert(_ text: String, validateDestination: () -> Bool) async -> Bool {
        let pasteboard = NSPasteboard.general

        // If the push-to-talk modifier is still physically held (auto-stop at
        // the recording cap), wait for it to lift so ⌘V isn't seen as ⌘⌥V.
        guard await waitForModifiersToLift(), !Task.isCancelled, validateDestination() else { return false }
        guard let temporary = TemporaryClipboard(text: text, pasteboard: pasteboard) else { return false }

        let sent = postCommandV()

        try? await Task.sleep(for: restoreDelay)
        temporary.restore(to: pasteboard)
        return sent
    }

    private static func waitForModifiersToLift(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState).rawValue & Hotkey.modifierMask
            if Task.isCancelled { return false }
            if flags == 0 { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    // MARK: Key synthesis

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            log.error("Could not create ⌘V events")
            return false
        }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.tag)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}

/// Owns Murmur's temporary clipboard entry and the deep snapshot it replaced.
/// The protected change count is captured after every Murmur write; capturing
/// it after `clearContents()` would make restoration fail because each later
/// `setString` increments the count again.
struct TemporaryClipboard {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    private let expectedChangeCount: Int

    init?(text: String, pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var entries: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entries[type] = data }
            }
            return entries
        }

        let clearedCount = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Self.restore(items, to: pasteboard, ifChangeCountIs: clearedCount)
            return nil
        }
        // De-facto clipboard-manager convention: this short-lived entry does
        // not belong in history because the prior clipboard is restored.
        pasteboard.setString("", forType: .transient)
        expectedChangeCount = pasteboard.changeCount
    }

    /// Restores the snapshot unless something else wrote after Murmur.
    func restore(to pasteboard: NSPasteboard) {
        Self.restore(items, to: pasteboard, ifChangeCountIs: expectedChangeCount)
    }

    private static func restore(
        _ items: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard,
        ifChangeCountIs expected: Int
    ) {
        guard pasteboard.changeCount == expected else { return }
        pasteboard.clearContents()
        let restored = items.compactMap { entries -> NSPasteboardItem? in
            guard !entries.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

extension NSPasteboard.PasteboardType {
    /// http://nspasteboard.org — clipboard managers skip items carrying it.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}
