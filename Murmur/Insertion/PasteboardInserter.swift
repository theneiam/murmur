import Foundation
import AppKit
import Carbon.HIToolbox
import os

/// Fallback insertion: put the text on the general pasteboard, synthesise
/// ⌘V into the frontmost app, then restore whatever was on the pasteboard
/// before. Works with virtually every app, at the cost of briefly touching
/// the clipboard.
enum PasteboardInserter {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "paste-insert")

    /// How long to wait after ⌘V before restoring the clipboard. Apps read the
    /// pasteboard synchronously while handling the key event, so this only
    /// needs to cover event delivery latency.
    static var restoreDelay: Duration = .milliseconds(250)

    @MainActor
    static func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = Snapshot(pasteboard)

        // If the push-to-talk modifier is still physically held (auto-stop at
        // the recording cap), wait for it to lift so ⌘V isn't seen as ⌘⌥V.
        await waitForModifiersToLift()

        let ourChangeCount = pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        try? await Task.sleep(for: restoreDelay)
        snapshot.restore(to: pasteboard, ifChangeCountIs: ourChangeCount)
    }

    private static func waitForModifiersToLift(timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState).rawValue & Hotkey.modifierMask
            if flags == 0 { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    // MARK: Key synthesis

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            log.error("Could not create ⌘V events")
            return
        }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyManager.syntheticEventTag)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: Clipboard snapshot

    /// A deep copy of every item/type on the pasteboard so it can be restored.
    private struct Snapshot {
        private let items: [[NSPasteboard.PasteboardType: Data]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                var entries: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        entries[type] = data
                    }
                }
                return entries
            }
        }

        /// Restores the snapshot unless something else wrote to the pasteboard
        /// after our paste — in that case the user's newer copy wins.
        func restore(to pasteboard: NSPasteboard, ifChangeCountIs expected: Int) {
            guard pasteboard.changeCount == expected else { return }
            pasteboard.clearContents()
            let restored = items.compactMap { entries -> NSPasteboardItem? in
                guard !entries.isEmpty else { return nil }
                let item = NSPasteboardItem()
                for (type, data) in entries {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restored.isEmpty {
                pasteboard.writeObjects(restored)
            }
        }
    }
}
