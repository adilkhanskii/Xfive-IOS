import Foundation
import CryptoKit

/// One-shot nonce generator for OAuth idToken flows (Apple, Google).
/// We send sha256(rawNonce) to the IdP as `nonce` claim in the request, then
/// pass the raw nonce alongside the idToken to Supabase. Supabase verifies the
/// hash matches the `nonce` claim Google/Apple baked into the token, blocking
/// idToken replay attacks.
enum Nonce {
    /// Cryptographically random 32-char string. Use as the raw nonce.
    static func random(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        for byte in bytes {
            let idx = Int(byte) % charset.count
            result.append(charset[idx])
        }
        return result
    }

    /// Hex-encoded SHA-256 of the raw nonce. Send this to the IdP.
    static func sha256(_ raw: String) -> String {
        let data = Data(raw.utf8)
        let hash = CryptoKit.SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
