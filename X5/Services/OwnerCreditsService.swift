import Foundation

/// Аккаунт из поиска owner_search_users (миграция 20261102120000).
struct OwnerCreditsUser: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let nickname: String?
    let email: String?
    let credits: Int

    init(id: String, name: String?, nickname: String?, email: String?, credits: Int) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.email = email
        self.credits = credits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        credits = try c.decodeIfPresent(Int.self, forKey: .credits) ?? 0
    }

    enum CodingKeys: String, CodingKey { case id, name, nickname, email, credits }

    /// Как показать человека: ник → имя → почта.
    var label: String {
        if let nick = nickname?.trimmingCharacters(in: .whitespaces), !nick.isEmpty {
            return nick.hasPrefix("@") ? nick : "@\(nick)"
        }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty { return email }
        return "—"
    }
}

/// Начисление кредитов владельцем (Адильхан 02.11). Границы — как в
/// owner_grant_credits / owner_search_users; сервер проверяет сам,
/// здесь — чтобы ошибка была видна до запроса.
enum OwnerCreditsError: String, Error, Equatable {
    case amount, query, access, notFound = "not_found", search, grant

    var localizationKey: String { "credits_ctl_err_\(rawValue)" }

    static let maxAmount = 100_000
    static let minQuery = 3
    static let maxNote = 200

    static func validate(amount: Int?) -> OwnerCreditsError? {
        guard let amount, (1...maxAmount).contains(amount) else { return .amount }
        return nil
    }

    static func canSearch(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minQuery
    }

    /// Ошибка PostgREST (code / message) → понятный текст.
    static func from(code: String?, message: String?, fallback: OwnerCreditsError) -> OwnerCreditsError {
        let message = message ?? ""
        if code == "42501" || message.contains("developer_required") { return .access }
        if message.contains("invalid_amount") { return .amount }
        if message.contains("query_too_short") { return .query }
        if message.contains("profile_not_found") || message.contains("target_required") { return .notFound }
        return fallback
    }

    /// Поле ввода: только цифры; пусто → nil.
    static func number(from text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits.prefix(6))
    }
}

/// Обе функции только для владельца: сервер проверяет is_x5_developer, иначе 42501.
enum OwnerCreditsService {
    static func search(
        query: String,
        accessToken: String,
        session: URLSession = .shared
    ) async -> Result<[OwnerCreditsUser], OwnerCreditsError> {
        let body: [String: Any] = ["p_query": query.trimmingCharacters(in: .whitespacesAndNewlines)]
        switch await rpc("owner_search_users", body: body, accessToken: accessToken, session: session, fallback: .search) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            guard let users = try? JSONDecoder().decode([OwnerCreditsUser].self, from: data) else { return .failure(.search) }
            return .success(users)
        }
    }

    /// Возвращает новый баланс аккаунта.
    static func grant(
        targetId: String,
        amount: Int,
        note: String,
        accessToken: String,
        session: URLSession = .shared
    ) async -> Result<Int, OwnerCreditsError> {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["p_target": targetId, "p_amount": amount]
        body["p_note"] = trimmed.isEmpty ? NSNull() : String(trimmed.prefix(OwnerCreditsError.maxNote))
        switch await rpc("owner_grant_credits", body: body, accessToken: accessToken, session: session, fallback: .grant) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            guard let balance = try? JSONDecoder().decode(Int.self, from: data) else { return .failure(.grant) }
            return .success(balance)
        }
    }

    private static func rpc(
        _ name: String,
        body: [String: Any],
        accessToken: String,
        session: URLSession,
        fallback: OwnerCreditsError
    ) async -> Result<Data, OwnerCreditsError> {
        var request = URLRequest(url: X5Config.supabaseBaseURL.appendingPathComponent("rest/v1/rpc/\(name)"))
        request.httpMethod = "POST"
        request.setValue(X5Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure(fallback) }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return .failure(.from(code: json?["code"] as? String, message: json?["message"] as? String, fallback: fallback))
        }
        return .success(data)
    }
}
