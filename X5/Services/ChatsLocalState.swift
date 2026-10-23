import Foundation

/// Per-chat local state stored in UserDefaults. WhatsApp/Telegram-style
/// archive / mute / delete that the user expects to "just work" on swipe
/// or long-press, without round-tripping a backend schema change.
///
/// Pure client filter — chats stay on the server, this just hides them
/// or suppresses notifications on the current device. Sign-out clears
/// the lists so a different account doesn't inherit the previous user's
/// hidden chats.
enum ChatsLocalState {
    private static let archivedKey = "x5.chats.archived_ids"
    private static let mutedKey = "x5.chats.muted_ids"
    private static let hiddenKey = "x5.chats.hidden_ids"
    private static let pinnedKey = "x5.chats.pinned_ids"

    // MARK: - Archived (folded into a separate "Архив" section)

    static var archived: Set<String> { read(archivedKey) }
    static func isArchived(_ id: String) -> Bool { archived.contains(id) }
    static func archive(_ id: String) { insert(id, key: archivedKey) }
    static func unarchive(_ id: String) { remove(id, key: archivedKey) }

    // MARK: - Muted (no notifications, badge-only)

    static var muted: Set<String> { read(mutedKey) }
    static func isMuted(_ id: String) -> Bool { muted.contains(id) }
    static func mute(_ id: String) { insert(id, key: mutedKey) }
    static func unmute(_ id: String) { remove(id, key: mutedKey) }

    // MARK: - Pinned (sticks to top of chat list, ahead of recent activity)

    static var pinned: Set<String> { read(pinnedKey) }
    static func isPinned(_ id: String) -> Bool { pinned.contains(id) }
    static func pin(_ id: String) { insert(id, key: pinnedKey) }
    static func unpin(_ id: String) { remove(id, key: pinnedKey) }

    // MARK: - Hidden ("deleted" client-side — the row is filtered out)

    static var hidden: Set<String> { read(hiddenKey) }
    static func isHidden(_ id: String) -> Bool { hidden.contains(id) }
    static func hide(_ id: String) {
        insert(id, key: hiddenKey)
        // A hidden chat doesn't need to be archived too — keep state clean.
        remove(id, key: archivedKey)
    }
    static func unhide(_ id: String) { remove(id, key: hiddenKey) }

    // MARK: - Sign-out wipe

    /// Called from Auth.signOut so a different account on the same device
    /// starts with a clean chat list.
    static func reset() {
        let d = UserDefaults.standard
        d.removeObject(forKey: archivedKey)
        d.removeObject(forKey: mutedKey)
        d.removeObject(forKey: hiddenKey)
        d.removeObject(forKey: pinnedKey)
    }

    // MARK: - Internals

    private static func read(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func insert(_ id: String, key: String) {
        var current = read(key)
        current.insert(id)
        UserDefaults.standard.set(Array(current), forKey: key)
    }

    private static func remove(_ id: String, key: String) {
        var current = read(key)
        current.remove(id)
        UserDefaults.standard.set(Array(current), forKey: key)
    }
}
