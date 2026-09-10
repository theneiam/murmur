import Foundation

/// Marker Murmur places in `eventSourceUserData` on keyboard events it posts
/// itself (the ⌘V used by the pasteboard inserter), so its own event tap
/// ignores them. Shared by the hotkey and insertion modules; keep the tag on
/// any new synthesized events.
enum SyntheticEvents {
    static let tag: Int64 = 0x4D75_726D // "Murm"
}
