import Foundation
import CryptoKit

enum StartupChatRole: String, Encodable, Equatable {
    case user
    case assistant
}

struct StartupChatMessage: Identifiable, Encodable, Equatable {
    let id: UUID
    let role: StartupChatRole
    let content: String

    init(
        id: UUID = UUID(),
        role: StartupChatRole,
        content: String
    ) {
        self.id = id
        self.role = role
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
    }
}

struct StartupChatReply: Decodable, Equatable {
    let reply: String
    let model: String?
}

enum StartupChatServiceError: LocalizedError, Equatable {
    case missingAccessToken
    case invalidConversation
    case contentRejected
    case assistantUnavailable
    case rateLimited(retryAfter: Int)
    case inProgress(retryAfter: Int)
    case transport
    case invalidResponse

    var retryAfterSeconds: Int? {
        switch self {
        case .rateLimited(let retryAfter),
             .inProgress(let retryAfter):
            return max(1, min(86_400, retryAfter))
        default:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "Войдите в аккаунт и повторите попытку."
        case .invalidConversation:
            return "Напишите вопрос о вашей идее."
        case .contentRejected:
            return "Сообщение не прошло проверку безопасности. Измените текст и попробуйте ещё раз."
        case .assistantUnavailable:
            return "Стартап-помощник временно недоступен. Попробуйте ещё раз."
        case .rateLimited(let retryAfter):
            if retryAfter >= 3_600 {
                return "Дневной лимит запросов исчерпан."
            }
            return "Лимит запросов. Попробуйте через \(retryAfter) сек."
        case .inProgress(let retryAfter):
            return "Ответ ещё формируется. Повторите через \(retryAfter) сек."
        case .transport:
            return "Не удалось связаться с сервером. Проверьте интернет."
        case .invalidResponse:
            return "Сервер вернул некорректный ответ. Попробуйте ещё раз."
        }
    }
}

final class StartupChatService {
    static let maxMessages = 12
    static let maxMessageCharacters = 4_000
    static let maxTotalCharacters = 12_000

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

    func send(
        messages: [StartupChatMessage],
        requestID: UUID = UUID(),
        accessToken: String
    ) async throws -> StartupChatReply {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw StartupChatServiceError.missingAccessToken
        }

        let normalized = try Self.normalizeForTransport(messages)
        guard !normalized.isEmpty, normalized.last?.role == .user else {
            throw StartupChatServiceError.invalidConversation
        }

        let url = baseURL.appendingPathComponent("functions/v1/startup-chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 55
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            StartupChatRequest(
                requestID: requestID,
                messages: normalized
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StartupChatServiceError.transport
        }

        guard let http = response as? HTTPURLResponse else {
            throw StartupChatServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (
                try? JSONDecoder().decode(
                    StartupChatErrorEnvelope.self,
                    from: data
                )
            )?.error?.code
            if http.statusCode == 401 || code == "not_authenticated" {
                throw StartupChatServiceError.missingAccessToken
            }
            let retryAfter = max(
                1,
                min(86_400, serverError(from: data)?.error?.retryAfter ?? 3)
            )
            if code == "rate_limited" {
                throw StartupChatServiceError.rateLimited(
                    retryAfter: retryAfter
                )
            }
            if code == "in_progress" {
                throw StartupChatServiceError.inProgress(
                    retryAfter: retryAfter
                )
            }
            if code == "content_rejected" {
                throw StartupChatServiceError.contentRejected
            }
            if code == "messages_required" ||
                code == "last_message_must_be_user" ||
                code == "invalid_request" ||
                code == "invalid_request_id" ||
                code == "idempotency_conflict" ||
                code == "replay_expired" ||
                code == "conversation_too_long" ||
                code == "too_many_messages" ||
                code == "message_too_long" ||
                code == "invalid_role" ||
                code == "message_empty" ||
                code == "invalid_message" {
                throw StartupChatServiceError.invalidConversation
            }
            throw StartupChatServiceError.assistantUnavailable
        }

        guard let decoded = try? JSONDecoder().decode(
            StartupChatReply.self,
            from: data
        ), let reply = try? Self.normalizeAssistantReply(decoded.reply)
        else {
            throw StartupChatServiceError.invalidResponse
        }
        return StartupChatReply(reply: reply, model: decoded.model)
    }

    static func normalizeForTransport(
        _ messages: [StartupChatMessage]
    ) throws -> [StartupChatMessage] {
        let candidates = messages.compactMap { message -> StartupChatMessage? in
            guard let content = try? normalizeUserMessage(message.content)
            else { return nil }
            return StartupChatMessage(
                id: message.id,
                role: message.role,
                content: content
            )
        }

        guard candidates.last?.role == .user else {
            throw StartupChatServiceError.invalidConversation
        }

        var selected: [StartupChatMessage] = []
        var totalCharacters = 0
        for message in candidates.suffix(maxMessages).reversed() {
            let messageCharacters = message.content.utf16.count
            guard totalCharacters + messageCharacters <= maxTotalCharacters
            else {
                break
            }
            selected.append(message)
            totalCharacters += messageCharacters
        }

        let result = selected.reversed()
        guard result.last?.role == .user else {
            throw StartupChatServiceError.invalidConversation
        }
        return Array(result)
    }

    static func normalizeUserMessage(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw StartupChatServiceError.invalidConversation
        }
        return prefixUTF16(clean, limit: maxMessageCharacters)
    }

    static func normalizeAssistantReply(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw StartupChatServiceError.invalidResponse
        }
        return prefixUTF16(clean, limit: maxMessageCharacters)
    }

    static func fingerprint(
        for messages: [StartupChatMessage]
    ) throws -> String {
        let normalized = try normalizeForTransport(messages)
        let canonical = normalized.map {
            "\($0.role.rawValue):\($0.content.utf16.count):\($0.content)"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func prefixUTF16(
        _ value: String,
        limit: Int
    ) -> String {
        let source = value as NSString
        guard source.length > limit else { return value }

        var length = limit
        if length > 0 {
            let lastUnit = Int(source.character(at: length - 1))
            if (0xD800...0xDBFF).contains(lastUnit) {
                length -= 1
            }
        }
        return source.substring(to: length)
    }

    private func serverError(from data: Data) -> StartupChatErrorEnvelope? {
        try? JSONDecoder().decode(StartupChatErrorEnvelope.self, from: data)
    }
}

private struct StartupChatRequest: Encodable {
    let requestID: UUID
    let messages: [StartupChatMessage]

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case messages
    }
}

private struct StartupChatErrorEnvelope: Decodable {
    let error: StartupChatServerError?
}

private struct StartupChatServerError: Decodable {
    let code: String?
    let retryAfter: Int?

    private enum CodingKeys: String, CodingKey {
        case code
        case retryAfter = "retry_after"
    }
}

struct StartupChatPendingRequest: Codable, Equatable {
    let requestID: UUID
    let fingerprint: String
}

final class StartupChatPendingRequestStore {
    private let defaults: UserDefaults
    private let keyPrefix = "x5.startup-chat.pending."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pending(userID: String) -> StartupChatPendingRequest? {
        guard let data = defaults.data(forKey: key(for: userID)),
              let value = try? JSONDecoder().decode(
                StartupChatPendingRequest.self,
                from: data
              )
        else {
            return nil
        }
        return value
    }

    func requestID(userID: String, fingerprint: String) -> UUID {
        if let existing = pending(userID: userID),
           existing.fingerprint == fingerprint {
            return existing.requestID
        }

        let value = StartupChatPendingRequest(
            requestID: UUID(),
            fingerprint: fingerprint
        )
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key(for: userID))
        }
        return value.requestID
    }

    func clear(
        userID: String,
        requestID: UUID
    ) {
        guard let existing = pending(userID: userID),
              existing.requestID == requestID
        else {
            return
        }
        defaults.removeObject(forKey: key(for: userID))
    }

    private func key(for userID: String) -> String {
        keyPrefix + userID
    }
}
