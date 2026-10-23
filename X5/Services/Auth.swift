import Foundation
import AuthenticationServices

enum JWTAccessTokenValidity {
    static func needsRefresh(
        _ token: String,
        now: Date = Date(),
        minimumValidity: TimeInterval
    ) -> Bool {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return true }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiration = (json["exp"] as? NSNumber)?.doubleValue
        else {
            return true
        }

        return expiration <= now.addingTimeInterval(minimumValidity).timeIntervalSince1970
    }
}

@MainActor
final class Auth: ObservableObject {
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var userEmail: String?
    @Published private(set) var userId: String?

    let supabase = SupabaseClient()

    var accessToken: String? { supabase.accessToken }

    /// Token keys live in the OS-protected Keychain, not plaintext preferences.
    /// Account identifiers (id, email; still personal data) stay in UserDefaults.
    private let tokenKey = "x5.session.access_token"
    private let refreshKey = "x5.session.refresh_token"
    private let userIdKey = "x5.session.user_id"
    private let emailKey = "x5.session.email"
    private let migrationFlag = "x5.session.keychain_migrated_v1"

    init() {
        migrateLegacyTokensToKeychain()

        // When SupabaseClient auto-refreshes the JWT (on a 401), persist the new tokens.
        supabase.onSessionRefreshed = { [weak self] session in
            guard let self else { return }
            Keychain.set(session.accessToken, for: self.tokenKey)
            if let refresh = session.refreshToken {
                Keychain.set(refresh, for: self.refreshKey)
            }
        }
        loadStoredSession()
    }

    /// One-time migration: tokens used to live in UserDefaults (plaintext, included
    /// in iTunes/iCloud backups). Move them to the Keychain on first run.
    private func migrateLegacyTokensToKeychain() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlag) else { return }
        if let access = defaults.string(forKey: tokenKey) {
            Keychain.set(access, for: tokenKey)
            defaults.removeObject(forKey: tokenKey)
        }
        if let refresh = defaults.string(forKey: refreshKey) {
            Keychain.set(refresh, for: refreshKey)
            defaults.removeObject(forKey: refreshKey)
        }
        defaults.set(true, forKey: migrationFlag)
    }

    func signInWithApple(authorization: ASAuthorization, rawNonce: String) async throws {
        guard !rawNonce.isEmpty,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            throw AuthError.invalidCredential
        }

        let session = try await supabase.signInWithApple(
            identityToken: identityToken,
            nonce: rawNonce
        )
        store(session: session)
    }

    /// Google Sign-In via the native iOS SDK (GIDSignIn). Trades the Google idToken
    /// for a Supabase session — same path as Apple Sign-In, no Safari involved.
    /// Bypasses Google's "unverified app" block that affected ASWebAuthenticationSession.
    func signInWithGoogle() async throws {
        let idToken = try await OAuthSession.shared.googleIdToken()
        let session = try await supabase.signInWithGoogle(idToken: idToken)
        store(session: session)
    }

    func signInWithEmail(_ email: String, password: String) async throws {
        let session = try await supabase.signInWithEmailPassword(email: email, password: password)
        store(session: session)
    }

    func signUpWithEmail(_ email: String, password: String) async throws {
        let session = try await supabase.signUpWithEmailPassword(email: email, password: password)
        store(session: session)
    }

    func signOut() async {
        let pushUnregistered: Bool
        if let userId, let accessToken {
            pushUnregistered = await PushNotifications.shared.unregisterCurrentDevice(
                userId: userId,
                accessToken: accessToken
            )
        } else {
            pushUnregistered = true
        }
        if !pushUnregistered {
            PushNotifications.shared.disableRemoteNotificationsAfterFailedUnregister()
        }
        clearStorage()
        supabase.accessToken = nil
        supabase.refreshToken = nil
        isAuthenticated = false
        userEmail = nil
        userId = nil
        // Invalidate account-owned UI/cache operations before cleanup can yield.
        NotificationCenter.default.post(name: .x5UserDidSignOut, object: nil)
        // Drop private chat media + in-memory layer so a different user signing
        // in on this device can't see leftovers from the previous session.
        await ImageCache.shared.clearForSignOut()
        // Per-chat local UI state (archived / muted / hidden) is per-account.
        ChatsLocalState.reset()
        MessagesLocalState.reset()
        // Wipe the per-chat message cache on disk — without this a different
        // user signing in on the same device could read the previous user's
        // message history (and signed media URLs) from `Caches/x5-chats/`.
        ChatsService.clearMemoryCache()
        ChatsService.clearDiskCache()
    }

    func freshAccessToken(
        minimumValidity: TimeInterval = 60,
        invalidateSessionOnCredentialFailure: Bool = true
    ) async -> String? {
        guard let token = accessToken else { return nil }
        guard JWTAccessTokenValidity.needsRefresh(
            token,
            minimumValidity: minimumValidity
        ) else { return token }
        guard supabase.refreshToken != nil else {
            // An expired JWT without a refresh token can never authenticate an
            // Edge Function. Keeping that state marked as signed in only makes
            // feature screens fail before their requests reach the server.
            if invalidateSessionOnCredentialFailure {
                await signOut()
            }
            return nil
        }

        // A mobile hand-off between Wi-Fi and cellular can make the first token
        // refresh fail even though the stored credentials are still valid. One
        // short retry avoids presenting a false authentication error while
        // credential rejections still invalidate the local session immediately.
        for attempt in 0..<2 {
            do {
                let session = try await supabase.refreshSession()
                return session.accessToken
            } catch let error as SupabaseError where error.invalidatesSession {
                if invalidateSessionOnCredentialFailure {
                    await signOut()
                }
                return nil
            } catch {
                guard attempt == 0 else { return nil }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        return nil
    }

    /// Supplies long-running uploads with a token that will remain valid for
    /// the next several chunks, refreshing only when the JWT is near expiry.
    func accessTokenForUpload(minimumValidity: TimeInterval = 10 * 60) async -> String? {
        await freshAccessToken(minimumValidity: minimumValidity)
    }

    /// Handles a server-rejected JWT through the same SupabaseClient
    /// single-flight refresh used by every other authenticated feature. The
    /// expected user prevents an old chat request from retrying as a newly
    /// signed-in account.
    func accessTokenAfterUnauthorized(
        rejectedAccessToken: String,
        expectedUserId: String
    ) async -> String? {
        guard userId == expectedUserId,
              let currentToken = accessToken
        else { return nil }
        if currentToken != rejectedAccessToken {
            // Another request already rotated the token for the same account.
            return currentToken
        }
        guard supabase.refreshToken != nil else {
            await signOut()
            return nil
        }
        do {
            let session = try await supabase.refreshSession()
            guard userId == expectedUserId else { return nil }
            return session.accessToken
        } catch let error as SupabaseError where error.invalidatesSession {
            guard userId == expectedUserId,
                  accessToken == rejectedAccessToken
            else { return nil }
            await signOut()
            return nil
        } catch {
            return nil
        }
    }

    func deleteAccount() async throws {
        try await supabase.deleteOwnAccount()
        await signOut()
    }

    // MARK: - Persistence

    private func loadStoredSession() {
        let defaults = UserDefaults.standard
        guard let token = Keychain.string(for: tokenKey),
              let uid = defaults.string(forKey: userIdKey)
        else {
            return
        }
        supabase.accessToken = token
        supabase.refreshToken = Keychain.string(for: refreshKey)
        userId = uid
        userEmail = defaults.string(forKey: emailKey)
        isAuthenticated = true
    }

    private func store(session: SupabaseSession) {
        Keychain.set(session.accessToken, for: tokenKey)
        Keychain.set(session.refreshToken, for: refreshKey)

        let defaults = UserDefaults.standard
        defaults.set(session.user.id, forKey: userIdKey)
        defaults.set(session.user.email, forKey: emailKey)

        supabase.accessToken = session.accessToken
        supabase.refreshToken = session.refreshToken
        userId = session.user.id
        userEmail = session.user.email
        isAuthenticated = true
    }

    private func clearStorage() {
        Keychain.delete(tokenKey)
        Keychain.delete(refreshKey)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: userIdKey)
        defaults.removeObject(forKey: emailKey)
    }
}

enum AuthError: LocalizedError {
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Apple did not return a valid identity token."
        }
    }
}
