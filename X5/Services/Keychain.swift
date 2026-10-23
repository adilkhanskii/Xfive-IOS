import Foundation
import Security

/// Thin wrapper around the iOS Keychain for storing OAuth/Supabase tokens.
/// Uses kSecClassGenericPassword with kSecAttrAccessibleAfterFirstUnlock so
/// tokens remain protected by the OS and are available after the first unlock.
/// This accessibility class does not promise exclusion from encrypted backups.
enum Keychain {
    private static let service = "app.x5studio.x5.session"

    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        // Nil → delete
        guard let value, let data = value.data(using: .utf8) else {
            return delete(key)
        }
        let base = baseQuery(for: key)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        // Try update first; fall back to add.
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            for (k, v) in attributes { insert[k] = v }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
    }
}
