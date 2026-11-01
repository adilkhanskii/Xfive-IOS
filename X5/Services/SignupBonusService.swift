import Foundation
import UIKit

/// Ответ RPC claim_signup_bonus (миграция 20261030181000, Адильхан 30.10).
struct SignupBonusClaim: Decodable {
    let status: String
    let credits: Int?
    let balance: Int?
}

/// Ответ RPC signup_bonus_stats — только для разработчика (иначе 42501).
struct SignupBonusStats: Decodable {
    let granted: Int
    let maxGrants: Int

    enum CodingKeys: String, CodingKey {
        case granted
        case maxGrants = "max_grants"
    }
}

/// Бонус новым: первым 1000 — 200 кредитов. Решает сервер, клиент только спрашивает один раз.
@MainActor
enum SignupBonusService {
    private static let deviceIdKey = "x5.device.install_id"
    private static let askedKeyPrefix = "x5.signup_bonus.asked."

    /// Эти ответы не окончательные — спросим при следующем запуске
    /// (почту подтвердят, профиль создастся, сессия обновится).
    static let retryStatuses: Set<String> = ["email_not_confirmed", "profile_missing", "not_signed_in"]

    /// id устройства в Keychain: переживает переустановку, в отличие от identifierForVendor.
    static func deviceId() -> String {
        if let saved = Keychain.string(for: deviceIdKey), saved.count >= 16 { return saved }
        let fresh = UUID().uuidString
        if Keychain.set(fresh, for: deviceIdKey) { return fresh }
        return UIDevice.current.identifierForVendor?.uuidString ?? fresh
    }

    static func wasAsked(userId: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: askedKeyPrefix + userId.lowercased())
    }

    /// nil — не спрашивали (уже спрошено) или сеть/функции ещё нет (404/PGRST202): повтор позже.
    static func claimIfNeeded(
        userId: String,
        accessToken: String,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) async -> SignupBonusClaim? {
        guard !wasAsked(userId: userId, defaults: defaults) else { return nil }
        let body = ["p_device_id": deviceId(), "p_platform": "ios"]
        guard let data = await rpc("claim_signup_bonus", body: body, accessToken: accessToken, session: session),
              let claim = try? JSONDecoder().decode(SignupBonusClaim.self, from: data)
        else { return nil }
        if !retryStatuses.contains(claim.status) {
            defaults.set(true, forKey: askedKeyPrefix + userId.lowercased())
        }
        return claim
    }

    /// nil — не разработчик, функции нет или сеть: строку в профиле прячем.
    static func stats(accessToken: String, session: URLSession = .shared) async -> SignupBonusStats? {
        guard let data = await rpc("signup_bonus_stats", body: [:], accessToken: accessToken, session: session) else {
            return nil
        }
        return try? JSONDecoder().decode(SignupBonusStats.self, from: data)
    }

    private static func rpc(
        _ name: String,
        body: [String: String],
        accessToken: String,
        session: URLSession
    ) async -> Data? {
        var request = URLRequest(url: X5Config.supabaseBaseURL.appendingPathComponent("rest/v1/rpc/\(name)"))
        request.httpMethod = "POST"
        request.setValue(X5Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }
}
