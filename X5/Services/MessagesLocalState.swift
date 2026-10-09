import Foundation

/// Per-message local state stored in UserDefaults. WhatsApp/Telegram-style
/// "Delete for me" — the message stays on the server (other participants
/// still see it) but is hidden on the current device.
///
/// Server-side delete-for-everyone needs an RPC + RLS policy and is deferred
/// to build 44+. This client filter is the MVP that closes the menu UX.
///
/// Sign-out clears the list so a different account on the same device
/// doesn't inherit the previous user's hidden messages.
enum MessagesLocalState {
    private static let hiddenKey = "x5.messages.hidden_ids"
    // Старый локальный закреп (до 09.10). Теперь закреп на сервере — chats.pinned_message_id;
    // ключ остался только чтобы reset() чистил хвосты у старых установок.
    private static let pinnedKey = "x5.messages.pinned_ids"

    static var hidden: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }

    static func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    static func hide(_ id: String) {
        var current = hidden
        current.insert(id)
        UserDefaults.standard.set(Array(current), forKey: hiddenKey)
    }

    static func unhide(_ id: String) {
        var current = hidden
        current.remove(id)
        UserDefaults.standard.set(Array(current), forKey: hiddenKey)
    }

    /// Called from Auth.signOut — keeps cross-account isolation.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: hiddenKey)
        UserDefaults.standard.removeObject(forKey: pinnedKey)
    }
}
