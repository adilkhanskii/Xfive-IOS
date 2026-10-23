import CryptoKit
import Foundation

enum VoiceGenerationVoice: String, CaseIterable, Hashable, Identifiable {
    case brightHeroine = "Russian_BrightHeroine"
    case ambitiousWoman = "Russian_AmbitiousWoman"
    case energeticWoman = "Russian_CrazyQueen"
    case calmGirl = "Russian_PessimisticGirl"
    case reliableMan = "Russian_ReliableMan"
    case youngMan = "Russian_AttractiveGuy"
    case sharpYoungVoice = "Russian_Bad-temperedBoy"
    case friendlyMan = "Russian_HandsomeChildhoodFriend"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightHeroine: return "Яркая героиня"
        case .ambitiousWoman: return "Уверенная женщина"
        case .energeticWoman: return "Энергичная женщина"
        case .calmGirl: return "Спокойная девушка"
        case .reliableMan: return "Надёжный мужчина"
        case .youngMan: return "Молодой мужчина"
        case .sharpYoungVoice: return "Резкий молодой голос"
        case .friendlyMan: return "Дружелюбный мужчина"
        }
    }

    /// Source compatibility for tests and pending requests created by an
    /// earlier TestFlight build. It is not shown in the current picker.
    static let aria = VoiceGenerationVoice.brightHeroine
}

enum VoiceGenerationStability: Double, CaseIterable, Hashable, Identifiable {
    case expressive = 0
    case balanced = 0.5
    case stable = 1

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .expressive:
            return "Живо"
        case .balanced:
            return "Баланс"
        case .stable:
            return "Стабильно"
        }
    }
}

struct VoiceGenerationResult: Decodable, Equatable {
    let audioURL: URL
    let audioURLExpiresAt: Date
    let creditsRemaining: Int
    let costCredits: Int
    let characterCount: Int
    let voice: String
    let model: String
    let replayed: Bool
    let assetID: String?

    enum CodingKeys: String, CodingKey {
        case audioURL = "audio_url"
        case audioURLExpiresAt = "audio_url_expires_at"
        case creditsRemaining = "credits_remaining"
        case costCredits = "cost_credits"
        case characterCount = "character_count"
        case voice
        case model
        case replayed
        case assetID = "asset_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioURL = try container.decode(URL.self, forKey: .audioURL)
        audioURLExpiresAt = try container.decode(
            Date.self,
            forKey: .audioURLExpiresAt
        )
        creditsRemaining = try container.decode(Int.self, forKey: .creditsRemaining)
        costCredits = try container.decode(Int.self, forKey: .costCredits)
        characterCount = try container.decodeIfPresent(
            Int.self,
            forKey: .characterCount
        ) ?? 0
        voice = try container.decode(String.self, forKey: .voice)
        model = try container.decode(String.self, forKey: .model)
        replayed = try container.decode(Bool.self, forKey: .replayed)
        assetID = try container.decodeIfPresent(String.self, forKey: .assetID)
    }
}

enum VoiceGenerationServiceError: LocalizedError, Equatable {
    case invalidText
    case invalidSpeed
    case invalidLanguage
    case invalidRequestID
    case missingAccessToken
    case transport
    case server(statusCode: Int, code: String?, refunded: Bool)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidText:
            return "Введите текст длиной от 1 до 5000 символов."
        case .invalidSpeed:
            return "Выберите доступную скорость озвучки."
        case .invalidLanguage:
            return "Выберите поддерживаемый язык."
        case .invalidRequestID:
            return "Не удалось подготовить запрос. Попробуйте ещё раз."
        case .missingAccessToken:
            return "Войдите в аккаунт и повторите попытку."
        case .transport:
            return "Нет связи с сервером озвучки. Проверьте интернет и повторите попытку."
        case .server(_, let code, let refunded):
            return Self.safeServerDescription(code: code, refunded: refunded)
        case .invalidResponse:
            return "Сервер вернул некорректный ответ. Повторите попытку."
        }
    }

    private static func safeServerDescription(
        code: String?,
        refunded: Bool
    ) -> String {
        switch code {
        case "insufficient_credits":
            return "Недостаточно кредитов для этой озвучки."
        case "generation_in_progress", "generation_status_pending":
            return "Озвучка ещё обрабатывается. Нажмите «Повторить», чтобы проверить результат."
        case "refund_pending":
            return "Статус операции уточняется. Кредиты не потеряются — повторите проверку чуть позже."
        case "voice_unavailable" where refunded:
            return "Сервис озвучки временно недоступен. Кредиты возвращены — попробуйте ещё раз."
        case "invalid_text", "invalid_voice", "invalid_stability",
             "invalid_speed", "invalid_language_code":
            return "Проверьте настройки озвучки и повторите попытку."
        case "unauthorized":
            return "Сессия истекла. Войдите в аккаунт и повторите попытку."
        default:
            return refunded
                ? "Озвучка не создана. Кредиты возвращены — попробуйте ещё раз."
                : "Сервис озвучки временно недоступен. Повторите попытку позже."
        }
    }
}

enum VoiceGenerationInputFingerprint {
    static func make(
        text: String,
        voice: VoiceGenerationVoice,
        stability: VoiceGenerationStability,
        speed: Double,
        languageCode: String?
    ) -> String {
        let normalizedLanguage = languageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let value = [
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            voice.rawValue,
            String(stability.rawValue),
            String(format: "%.1f", speed),
            normalizedLanguage
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class VoiceGenerationLocalStore {
    private struct PendingRequest: Codable {
        let requestID: String
        let fingerprint: String
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let keyPrefix = "x5.voice.pending.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pendingRequestID(
        for fingerprint: String,
        userID: String
    ) -> String {
        let key = storageKey(userID: userID, fingerprint: fingerprint)
        lock.lock()
        defer { lock.unlock() }

        if let data = defaults.data(forKey: key),
           let pending = try? JSONDecoder().decode(
               PendingRequest.self,
               from: data
           ),
           pending.fingerprint == fingerprint,
           UUID(uuidString: pending.requestID) != nil {
            return pending.requestID
        }

        let requestID = UUID().uuidString.lowercased()
        let pending = PendingRequest(
            requestID: requestID,
            fingerprint: fingerprint
        )
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: key)
        }
        return requestID
    }

    func clearPending(
        acceptedRequestID: String,
        fingerprint: String,
        userID: String
    ) {
        let key = storageKey(userID: userID, fingerprint: fingerprint)
        lock.lock()
        defer { lock.unlock() }

        guard
            let data = defaults.data(forKey: key),
            let pending = try? JSONDecoder().decode(
                PendingRequest.self,
                from: data
            ),
            pending.requestID == acceptedRequestID
        else {
            return
        }
        defaults.removeObject(forKey: key)
    }

    private func storageKey(userID: String, fingerprint: String) -> String {
        let owner = userID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let input = fingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(keyPrefix)\(owner).\(input)"
    }
}

final class VoiceGenerationService {
    static let maxCharacters = 5_000
    static let creditsPerBlock = 60
    static let maxPendingPolls = 60

    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String
    private let decoder: JSONDecoder
    private let sleeper: (UInt64) async throws -> Void

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey,
        sleeper: @escaping (UInt64) async throws -> Void = { seconds in
            try await Task.sleep(
                nanoseconds: seconds * 1_000_000_000
            )
        }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.sleeper = sleeper

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        self.decoder = decoder
    }

    static func creditCost(for text: String) -> Int {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characterCount = cleanText.utf16.count
        guard characterCount > 0 else { return 0 }
        return Int(ceil(Double(characterCount) / 1_000.0)) * creditsPerBlock
    }

    func generate(
        text: String,
        voice: VoiceGenerationVoice,
        stability: VoiceGenerationStability,
        speed: Double,
        languageCode: String?,
        requestID: String,
        accessToken: String
    ) async throws -> VoiceGenerationResult {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characterCount = cleanText.utf16.count
        guard (1...Self.maxCharacters).contains(characterCount) else {
            throw VoiceGenerationServiceError.invalidText
        }
        guard Self.isSupportedSpeed(speed) else {
            throw VoiceGenerationServiceError.invalidSpeed
        }

        let cleanLanguage = languageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let cleanLanguage, !cleanLanguage.isEmpty,
           cleanLanguage.range(
               of: "^[a-z]{2}$",
               options: .regularExpression
           ) == nil {
            throw VoiceGenerationServiceError.invalidLanguage
        }

        let normalizedRequestID = requestID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard UUID(uuidString: normalizedRequestID) != nil else {
            throw VoiceGenerationServiceError.invalidRequestID
        }

        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw VoiceGenerationServiceError.missingAccessToken
        }

        let payload = VoiceGenerationRequest(
            text: cleanText,
            voice: voice.rawValue,
            stability: stability.rawValue,
            speed: speed,
            languageCode: cleanLanguage?.isEmpty == false ? cleanLanguage : nil,
            requestID: normalizedRequestID
        )
        let url = baseURL.appendingPathComponent("functions/v1/generate-voice")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(normalizedRequestID, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(payload)

        for poll in 0...Self.maxPendingPolls {
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw VoiceGenerationServiceError.invalidResponse
                }
                if (200..<300).contains(http.statusCode) {
                    return try decodeResult(from: data)
                }

                let envelope = try? decoder.decode(
                    VoiceGenerationErrorEnvelope.self,
                    from: data
                )
                if http.statusCode == 425,
                   envelope?.error.code == "generation_status_pending",
                   poll < Self.maxPendingPolls {
                    try await sleeper(
                        Self.pendingDelaySeconds(
                            retryAfter: http.value(
                                forHTTPHeaderField: "Retry-After"
                            )
                        )
                    )
                    continue
                }
                throw VoiceGenerationServiceError.server(
                    statusCode: http.statusCode,
                    code: envelope?.error.code,
                    refunded: envelope?.refunded ?? false
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as VoiceGenerationServiceError {
                throw error
            } catch {
                throw VoiceGenerationServiceError.transport
            }
        }
        throw VoiceGenerationServiceError.invalidResponse
    }

    /// Retries exactly once when the Edge Function rejects an access token.
    /// The request ID remains unchanged, so the server-side idempotency ledger
    /// prevents a duplicate debit if the first response was interrupted.
    func generateWithTokenRefresh(
        text: String,
        voice: VoiceGenerationVoice,
        stability: VoiceGenerationStability,
        speed: Double,
        languageCode: String?,
        requestID: String,
        accessToken: String,
        refreshAccessToken: @escaping (String) async -> String?
    ) async throws -> VoiceGenerationResult {
        do {
            return try await generate(
                text: text,
                voice: voice,
                stability: stability,
                speed: speed,
                languageCode: languageCode,
                requestID: requestID,
                accessToken: accessToken
            )
        } catch let error as VoiceGenerationServiceError {
            guard case .server(let statusCode, _, _) = error,
                  statusCode == 401
            else {
                throw error
            }

            guard let refreshedToken = await refreshAccessToken(accessToken),
                  !refreshedToken.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                throw VoiceGenerationServiceError.missingAccessToken
            }

            return try await generate(
                text: text,
                voice: voice,
                stability: stability,
                speed: speed,
                languageCode: languageCode,
                requestID: requestID,
                accessToken: refreshedToken
            )
        }
    }

    private static func isSupportedSpeed(_ speed: Double) -> Bool {
        guard speed >= 0.7, speed <= 1.2 else { return false }
        return abs(speed * 10 - (speed * 10).rounded()) < 0.000_001
    }

    private static func pendingDelaySeconds(
        retryAfter: String?
    ) -> UInt64 {
        guard let retryAfter,
              let value = Double(
                retryAfter.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ),
              value.isFinite
        else {
            return 2
        }
        return UInt64(min(5, max(1, value.rounded(.up))))
    }

    private func decodeResult(from data: Data) throws -> VoiceGenerationResult {
        do {
            let result = try decoder.decode(
                VoiceGenerationResult.self,
                from: data
            )
            guard
                result.audioURL.scheme?.lowercased() == "https",
                result.audioURL.host?.lowercased()
                    == baseURL.host?.lowercased()
            else {
                throw VoiceGenerationServiceError.invalidResponse
            }
            return result
        } catch {
            if let error = error as? VoiceGenerationServiceError {
                throw error
            }
            throw VoiceGenerationServiceError.invalidResponse
        }
    }
}

private struct VoiceGenerationRequest: Encodable {
    let text: String
    let voice: String
    let stability: Double
    let speed: Double
    let languageCode: String?
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case text
        case voice
        case stability
        case speed
        case languageCode = "language_code"
        case requestID = "request_id"
    }
}

private struct VoiceGenerationErrorEnvelope: Decodable {
    struct SafeError: Decodable {
        let code: String?
    }

    let error: SafeError
    let refunded: Bool?
}

enum VoiceGenerationShareFileError: LocalizedError, Equatable {
    case invalidURL
    case downloadFailed
    case invalidAudio
    case fileWriteFailed

    var errorDescription: String? {
        "Не удалось подготовить MP3 для отправки. Попробуйте ещё раз."
    }
}

final class VoiceGenerationShareFileService {
    static let maximumAudioBytes = 20 * 1024 * 1024

    private let session: URLSession
    private let expectedHost: String
    private let fileManager: FileManager
    private let directory: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) {
        self.session = session
        expectedHost = baseURL.host?.lowercased() ?? ""
        self.fileManager = fileManager
        self.directory = directory
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "x5-voice-share",
                isDirectory: true
            )
    }

    func prepare(
        audioURL: URL,
        requestID: String
    ) async throws -> URL {
        guard audioURL.scheme?.lowercased() == "https",
              audioURL.host?.lowercased() == expectedHost,
              UUID(uuidString: requestID) != nil
        else {
            throw VoiceGenerationShareFileError.invalidURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: audioURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VoiceGenerationShareFileError.downloadFailed
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == expectedHost,
              data.count > 3,
              data.count <= Self.maximumAudioBytes,
              Self.looksLikeMP3(data)
        else {
            throw VoiceGenerationShareFileError.invalidAudio
        }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent(
                "x5-voice-\(requestID.lowercased()).mp3",
                isDirectory: false
            )
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            throw VoiceGenerationShareFileError.fileWriteFailed
        }
    }

    func remove(_ fileURL: URL?) {
        guard let fileURL,
              fileURL.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL
        else {
            return
        }
        try? fileManager.removeItem(at: fileURL)
    }

    private static func looksLikeMP3(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        if bytes == [0x49, 0x44, 0x33] {
            return true
        }
        guard bytes.count >= 2 else { return false }
        return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0
    }
}
