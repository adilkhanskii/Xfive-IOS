import XCTest
import Security
@testable import X5

/// Actual OS Keychain, with a disposable synthetic value (never session tokens).
/// Running unsigned and ad-hoc signed separates runner entitlements from app code.
final class KeychainPersistenceTests: XCTestCase {
    func testOSKeychainAndSessionWrapperRoundTrip() {
        let key = "x5.audit.keychain.\(UUID().uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "app.x5studio.x5.audit",
            kSecAttrAccount: key,
            kSecValueData: Data("synthetic-probe".utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        defer {
            SecItemDelete([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: "app.x5studio.x5.audit",
                kSecAttrAccount: key
            ] as CFDictionary)
            Keychain.delete(key)
        }
        XCTAssertEqual(status, errSecSuccess, "OS Keychain write status: \(status)")
        XCTAssertTrue(Keychain.set("synthetic-v1", for: key))
        XCTAssertEqual(Keychain.string(for: key), "synthetic-v1")
        XCTAssertTrue(Keychain.set("synthetic-v2", for: key))
        XCTAssertEqual(Keychain.string(for: key), "synthetic-v2")
        XCTAssertTrue(Keychain.delete(key))
        XCTAssertNil(Keychain.string(for: key))
    }
}
