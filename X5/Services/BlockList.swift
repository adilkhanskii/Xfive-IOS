import Foundation

/// Local block list — list of user_ids the current device should hide.
/// Stored in UserDefaults. Pure-client filter; required by App Review for
/// any app with user-generated content (Guideline 1.2).
enum BlockList {
    private static let key = "x5.blocked_user_ids"

    static var ids: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    static func add(_ id: String) {
        var current = ids
        current.insert(id)
        UserDefaults.standard.set(Array(current), forKey: key)
    }

    static func remove(_ id: String) {
        var current = ids
        current.remove(id)
        UserDefaults.standard.set(Array(current), forKey: key)
    }
}
