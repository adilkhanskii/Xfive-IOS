import Foundation
import UIKit

/// Ответ RPC claim_signup_bonus (миграция 20261030181000, Адильхан 30.10).
struct SignupBonusClaim: Decodable {
    let status: String
    let credits: Int?
    let balance: Int?
}

/// Ответ RPC signup_bonus_stats / signup_bonus_update_settings — только для разработчика (иначе 42501).
struct SignupBonusStats: Decodable, Equatable {
    let granted: Int
    let maxGrants: Int
    let credits: Int
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case granted
        case maxGrants = "max_grants"
        case credits
        case enabled
    }

    init(granted: Int, maxGrants: Int, credits: Int, enabled: Bool) {
        self.granted = granted
        self.maxGrants = maxGrants
        self.credits = credits
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        granted = try c.decode(Int.self, forKey: .granted)
        maxGrants = try c.decode(Int.self, forKey: .maxGrants)
        // Поля добавлены позже — если их нет, показываем как «включён, 200»
        credits = try c.decodeIfPresent(Int.self, forKey: .credits) ?? 200
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Управление бонусом новым (владелец, Адильхан 01.11). Границы — как в
/// signup_bonus_update_settings (миграция 20261101120000); сервер проверяет сам,
/// здесь — чтобы ошибка была видна до запроса.
enum SignupBonusSettingsError: String, Error, Equatable {
    case credits, limit, access, save

    var localizationKey: String { "bonus_ctl_err_\(rawValue)" }

    static let maxCredits = 10_000
    static let maxLimit = 1_000_000

    static func validate(credits: Int?, maxGrants: Int?, granted: Int) -> SignupBonusSettingsError? {
        guard let credits, (1...maxCredits).contains(credits) else { return .credits }
        guard let maxGrants, maxGrants >= granted, maxGrants <= maxLimit else { return .limit }
        return nil
    }

    /// Ошибка PostgREST (code / message) → понятный текст.
    static func from(code: String?, message: String?) -> SignupBonusSettingsError {
        let message = message ?? ""
        if code == "42501" || message.contains("developer_required") { return .access }
        if message.contains("invalid_credits") { return .credits }
        if message.contains("max_grants") { return .limit }
        return .save
    }

    /// Поле ввода: только цифры; пусто → nil.
    static func number(from text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits.prefix(7))
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

    /// Пауза / возобновление / подарок / лимит. Права проверяет сервер (is_x5_developer).
    static func updateSettings(
        enabled: Bool,
        credits: Int,
        maxGrants: Int,
        accessToken: String,
        session: URLSession = .shared
    ) async -> Result<SignupBonusStats, SignupBonusSettingsError> {
        var request = URLRequest(url: X5Config.supabaseBaseURL.appendingPathComponent("rest/v1/rpc/signup_bonus_update_settings"))
        request.httpMethod = "POST"
        request.setValue(X5Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["p_enabled": enabled, "p_credits": credits, "p_max_grants": maxGrants]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure(.save) }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return .failure(.from(code: json?["code"] as? String, message: json?["message"] as? String))
        }
        guard let stats = try? JSONDecoder().decode(SignupBonusStats.self, from: data) else { return .failure(.save) }
        return .success(stats)
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
