import Foundation

enum CoursePurchaseStatus: Equatable, Codable {
    case purchased
    case alreadyOwned
    case insufficientCredits
    case priceChanged
    case courseUnavailable
    case lessonUnavailable
    case profileUnavailable
    case notAuthenticated
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "purchased": self = .purchased
        case "already_owned": self = .alreadyOwned
        case "insufficient_credits": self = .insufficientCredits
        case "price_changed": self = .priceChanged
        case "course_unavailable": self = .courseUnavailable
        case "lesson_unavailable": self = .lessonUnavailable
        case "profile_unavailable": self = .profileUnavailable
        case "not_authenticated": self = .notAuthenticated
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        let value: String
        switch self {
        case .purchased: value = "purchased"
        case .alreadyOwned: value = "already_owned"
        case .insufficientCredits: value = "insufficient_credits"
        case .priceChanged: value = "price_changed"
        case .courseUnavailable: value = "course_unavailable"
        case .lessonUnavailable: value = "lesson_unavailable"
        case .profileUnavailable: value = "profile_unavailable"
        case .notAuthenticated: value = "not_authenticated"
        case .unknown(let rawValue): value = rawValue
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Result of `purchase_lesson`, the server-priced flow that sells one lesson
/// without the rest of the course. `lessonKey` is the entitlement the server
/// appended to `purchased_lesson_ids`; the client must never build it itself.
struct LessonPurchaseResponse: Codable, Equatable {
    let status: CoursePurchaseStatus
    let courseId: String
    let lessonId: String
    let lessonKey: String
    let creditsRemaining: Int?
    let lessonPrice: Int?
    let chargedAmount: Int?
    /// Конец доступа (30 дней) — сервер присылает при status purchased; у старой базы поля нет.
    var accessExpiresAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case status
        case courseId = "course_id"
        case lessonId = "lesson_id"
        case lessonKey = "lesson_key"
        case creditsRemaining = "credits_remaining"
        case lessonPrice = "lesson_price"
        case chargedAmount = "charged_amount"
        case accessExpiresAt = "access_expires_at"
    }

    /// Ownership counts only when the server also returned the key it stored,
    /// so a malformed success can never unlock a lesson locally.
    var grantsOwnership: Bool {
        guard status == .purchased || status == .alreadyOwned else { return false }
        return !lessonKey.isEmpty
    }

    func reconciledExpectedPrice(currentPrice: Int) -> Int {
        guard status == .priceChanged, let lessonPrice else {
            return max(currentPrice, 0)
        }
        return max(lessonPrice, 0)
    }
}

struct CoursePurchaseResponse: Codable, Equatable {
    let status: CoursePurchaseStatus
    let courseId: String
    let creditsRemaining: Int?
    let coursePrice: Int?
    let chargedAmount: Int?
    /// Конец доступа (30 дней) — сервер присылает при status purchased; у старой базы поля нет.
    var accessExpiresAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case status
        case courseId = "course_id"
        case creditsRemaining = "credits_remaining"
        case coursePrice = "course_price"
        case chargedAmount = "charged_amount"
        case accessExpiresAt = "access_expires_at"
    }

    var grantsOwnership: Bool {
        status == .purchased || status == .alreadyOwned
    }

    /// Reconciles the price the user must explicitly confirm on the next
    /// attempt. A price-changed response never charges, so adopting the
    /// server-returned value is safe only after showing a fresh confirmation.
    func reconciledExpectedPrice(currentPrice: Int) -> Int {
        guard status == .priceChanged, let coursePrice else {
            return max(currentPrice, 0)
        }
        return max(coursePrice, 0)
    }
}

enum CoursePurchaseServiceError: LocalizedError, Equatable {
    case invalidCourseId
    case invalidLessonId
    case missingAccessToken
    case transport(String)
    case http(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidCourseId:
            return "Некорректный идентификатор курса."
        case .invalidLessonId:
            return "Некорректный идентификатор урока."
        case .missingAccessToken:
            return "Войдите в аккаунт, чтобы купить курс."
        case .transport:
            return "Не удалось связаться с сервером. Проверьте интернет и повторите попытку."
        case .http(let statusCode, let message):
            let suffix = message.isEmpty ? "" : " \(message)"
            return "Покупка не выполнена (\(statusCode)).\(suffix)"
        case .invalidResponse:
            return "Сервер вернул некорректный ответ. Повторите попытку."
        }
    }
}

@MainActor
final class CoursePurchaseService: ObservableObject {
    @Published private(set) var isPurchasing = false
    @Published private(set) var error: String?

    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
    }

    func purchase(
        courseId: String,
        expectedPrice: Int,
        accessToken: String,
        refreshAccessToken: (() async -> String?)? = nil
    ) async throws -> CoursePurchaseResponse {
        let trimmedCourseId = courseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmedCourseId) != nil else {
            throw record(.invalidCourseId)
        }
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw record(.missingAccessToken)
        }

        struct PurchaseRequest: Encodable {
            let pCourseId: String
            let pExpectedPrice: Int

            enum CodingKeys: String, CodingKey {
                case pCourseId = "p_course_id"
                case pExpectedPrice = "p_expected_price"
            }
        }

        return try await callPurchaseRPC(
            named: "purchase_course",
            body: PurchaseRequest(
                pCourseId: trimmedCourseId,
                pExpectedPrice: max(expectedPrice, 0)
            ),
            accessToken: accessToken,
            refreshAccessToken: refreshAccessToken
        )
    }

    /// Buys a single lesson. The server owns the price and refuses previews,
    /// unpriced lessons and lessons the author did not mark as sold separately,
    /// so the caller only has to confirm the amount it displayed.
    func purchaseLesson(
        courseId: String,
        lessonId: String,
        expectedPrice: Int,
        accessToken: String,
        refreshAccessToken: (() async -> String?)? = nil
    ) async throws -> LessonPurchaseResponse {
        let trimmedCourseId = courseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmedCourseId) != nil else {
            throw record(.invalidCourseId)
        }
        let trimmedLessonId = lessonId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLessonId.isEmpty, trimmedLessonId.count <= 256 else {
            throw record(.invalidLessonId)
        }
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw record(.missingAccessToken)
        }

        struct LessonRequest: Encodable {
            let pCourseId: String
            let pLessonId: String
            let pExpectedPrice: Int

            enum CodingKeys: String, CodingKey {
                case pCourseId = "p_course_id"
                case pLessonId = "p_lesson_id"
                case pExpectedPrice = "p_expected_price"
            }
        }

        return try await callPurchaseRPC(
            named: "purchase_lesson",
            body: LessonRequest(
                pCourseId: trimmedCourseId,
                pLessonId: trimmedLessonId,
                pExpectedPrice: max(expectedPrice, 0)
            ),
            accessToken: accessToken,
            refreshAccessToken: refreshAccessToken
        )
    }

    private func callPurchaseRPC<Body: Encodable, Result: Decodable>(
        named rpc: String,
        body: Body,
        accessToken: String,
        refreshAccessToken: (() async -> String?)?
    ) async throws -> Result {
        isPurchasing = true
        error = nil
        defer { isPurchasing = false }

        let url = baseURL.appendingPathComponent("rest/v1/rpc/\(rpc)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        var didRetryUnauthorized = false

        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw record(.transport(error.localizedDescription))
            }

            guard let http = response as? HTTPURLResponse else {
                throw record(.invalidResponse)
            }

            if http.statusCode == 401,
               !didRetryUnauthorized,
               let refreshAccessToken {
                // Authentication is rejected before PostgREST invokes the RPC,
                // so this is the only POST failure that is safe to retry. Mark
                // the attempt before awaiting to guarantee a strict one-retry cap.
                didRetryUnauthorized = true
                guard let refreshedToken = await refreshAccessToken()?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !refreshedToken.isEmpty else {
                    throw record(.missingAccessToken)
                }
                request.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                continue
            }

            guard (200..<300).contains(http.statusCode) else {
                let message = Self.serverMessage(from: data)
                throw record(.http(statusCode: http.statusCode, message: message))
            }

            do {
                return try JSONDecoder().decode(Result.self, from: data)
            } catch {
                // Some PostgREST configurations wrap a scalar JSON result in a
                // single-element array. Accept both forms without weakening types.
                if let first = try? JSONDecoder().decode([Result].self, from: data).first {
                    return first
                }
                throw record(.invalidResponse)
            }
        }
    }

    @discardableResult
    private func record(_ serviceError: CoursePurchaseServiceError) -> CoursePurchaseServiceError {
        error = serviceError.localizedDescription
        return serviceError
    }

    private static func serverMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable { let message: String? }

        guard let raw = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).message else {
            return ""
        }
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(240))
    }
}
