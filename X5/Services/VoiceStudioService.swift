import Foundation

/// «Мои голоса» премиум-озвучки — функция voice-studio на сервере.
/// Ключ провайдера и списание кредитов только на сервере.
struct VoiceStudioPremadeVoice: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let gender: String?
    let previewURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case gender
        case previewURL = "preview_url"
    }

    init(id: String, name: String, gender: String?, previewURL: URL?) {
        self.id = id
        self.name = name
        self.gender = gender
        self.previewURL = previewURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        gender = try container.decodeIfPresent(String.self, forKey: .gender)
        // Образец ▶ только по https-ссылке от сервера.
        let raw = try container.decodeIfPresent(String.self, forKey: .previewURL)
        if let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" {
            previewURL = url
        } else {
            previewURL = nil
        }
    }
}

struct VoiceStudioMyVoice: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let source: String

    var isClone: Bool { source == "clone" }
}

struct VoiceStudioCatalog: Decodable, Equatable {
    struct Prices: Decodable, Equatable {
        let clone: Int
        let design: Int
        let save: Int
    }

    let premiumAvailable: Bool
    let prices: Prices
    let voiceLimit: Int
    let premade: [VoiceStudioPremadeVoice]
    let myVoices: [VoiceStudioMyVoice]
    /// Клон голоса включён на сервере (нужен тариф Starter у провайдера).
    /// Нет поля (старый сервер) — считаем, что включён.
    var cloneAvailableFlag: Bool? = nil

    var cloneAvailable: Bool { cloneAvailableFlag ?? true }

    enum CodingKeys: String, CodingKey {
        case premiumAvailable = "premium_available"
        case cloneAvailableFlag = "clone_available"
        case prices
        case voiceLimit = "voice_limit"
        case premade
        case myVoices = "my_voices"
    }

    /// Пока сервер не ответил — карточки без ▶ и «скоро».
    static let offline = VoiceStudioCatalog(
        premiumAvailable: false,
        prices: Prices(clone: 300, design: 50, save: 0),
        voiceLimit: 3,
        premade: VoiceGenerationPremiumVoice.allCases.map {
            VoiceStudioPremadeVoice(
                id: $0.rawValue,
                name: $0.shortName,
                gender: $0.isFemale ? "female" : "male",
                previewURL: nil
            )
        },
        myVoices: []
    )
}

struct VoiceStudioDesignPreview: Identifiable, Equatable {
    let id: String
    let audio: Data
    let durationSeconds: Double
}

enum VoiceStudioError: LocalizedError, Equatable {
    case server(code: String?, cost: Int?)
    case transport
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "Войдите в аккаунт и повторите попытку."
        case .transport:
            return "Нет связи с сервером. Ничего не списано — повторите попытку."
        case .server(let code, let cost):
            switch code {
            case "insufficient_credits":
                return "Недостаточно кредитов\(cost.map { ": нужно \($0)" } ?? ""). Ничего не списано."
            case "voice_limit":
                return "Можно хранить до 3 своих голосов — удалите один, чтобы добавить новый."
            case "consent_required":
                return "Подтвердите, что это ваш голос."
            case "invalid_audio_type":
                return "Нужен файл mp3, m4a или wav."
            case "audio_too_large":
                return "Файл больше 10 МБ."
            case "audio_too_short":
                return "Запись слишком короткая — нужно от 30 секунд."
            case "invalid_name":
                return "Введите название голоса до 40 символов."
            case "invalid_description":
                return "Опишите голос подробнее — от 20 символов."
            case "premium_unavailable":
                return "Премиум-голоса скоро появятся. Ничего не списано."
            case "clone_requires_plan":
                return "Свой голос пока недоступен — нужен тариф Starter. Кредиты не списаны."
            case "provider_rejected":
                return "Не удалось создать голос. Кредиты не списаны — попробуйте другую запись."
            default:
                return "Сервис голосов временно недоступен. Ничего не списано."
            }
        }
    }
}

final class VoiceStudioService {
    static let cloneMinSeconds: TimeInterval = 30
    static let cloneMaxSeconds: TimeInterval = 90
    static let cloneMaxBytes = 10 * 1024 * 1024

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

    func catalog(accessToken: String) async throws -> VoiceStudioCatalog {
        let data = try await send(json: ["action": "catalog"], accessToken: accessToken)
        return try decode(VoiceStudioCatalog.self, from: data)
    }

    /// Клон: запись/файл уходит на сервер, тот — провайдеру; у нас не хранится.
    func clone(
        name: String,
        audio: Data,
        mimeType: String,
        fileExtension: String,
        consent: Bool,
        accessToken: String
    ) async throws -> (voice: VoiceStudioMyVoice, creditsRemaining: Int) {
        guard consent else {
            throw VoiceStudioError.server(code: "consent_required", cost: nil)
        }
        guard audio.count <= Self.cloneMaxBytes else {
            throw VoiceStudioError.server(code: "audio_too_large", cost: nil)
        }
        let boundary = "x5-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("action", "clone")
        field("request_id", UUID().uuidString.lowercased())
        field("name", name.trimmingCharacters(in: .whitespacesAndNewlines))
        field("consent", "true")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.\(fileExtension)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n")

        let data = try await send(
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            accessToken: accessToken,
            timeout: 150
        )
        let payload = try decode(VoiceEnvelope.self, from: data)
        return (payload.voice, payload.creditsRemaining)
    }

    func design(
        description: String,
        accessToken: String
    ) async throws -> (previews: [VoiceStudioDesignPreview], creditsRemaining: Int) {
        let data = try await send(
            json: [
                "action": "design",
                "request_id": UUID().uuidString.lowercased(),
                "description": description.trimmingCharacters(in: .whitespacesAndNewlines)
            ],
            accessToken: accessToken,
            timeout: 150
        )
        let payload = try decode(DesignEnvelope.self, from: data)
        let previews = payload.previews.compactMap { preview -> VoiceStudioDesignPreview? in
            guard let audio = Data(base64Encoded: preview.audioBase64) else { return nil }
            return VoiceStudioDesignPreview(
                id: preview.generatedVoiceID,
                audio: audio,
                durationSeconds: preview.durationSecs ?? 0
            )
        }
        return (previews, payload.creditsRemaining)
    }

    func saveDesign(
        generatedVoiceID: String,
        name: String,
        description: String,
        accessToken: String
    ) async throws -> VoiceStudioMyVoice {
        let data = try await send(
            json: [
                "action": "save_design",
                "request_id": UUID().uuidString.lowercased(),
                "generated_voice_id": generatedVoiceID,
                "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                "description": description.trimmingCharacters(in: .whitespacesAndNewlines)
            ],
            accessToken: accessToken
        )
        return try decode(VoiceEnvelope.self, from: data).voice
    }

    func delete(voiceID: String, accessToken: String) async throws {
        _ = try await send(
            json: ["action": "delete", "voice_id": voiceID],
            accessToken: accessToken
        )
    }

    // MARK: - Transport

    private func send(
        json: [String: String],
        accessToken: String,
        timeout: TimeInterval = 60
    ) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(
            body: body,
            contentType: "application/json",
            accessToken: accessToken,
            timeout: timeout
        )
    }

    private func send(
        body: Data,
        contentType: String,
        accessToken: String,
        timeout: TimeInterval
    ) async throws -> Data {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw VoiceStudioError.missingAccessToken }
        var request = URLRequest(url: baseURL.appendingPathComponent("functions/v1/voice-studio"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VoiceStudioError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw VoiceStudioError.transport
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(VoiceStudioErrorEnvelope.self, from: data)
            throw VoiceStudioError.server(
                code: envelope?.error.code,
                cost: envelope?.costCredits
            )
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw VoiceStudioError.server(code: "invalid_response", cost: nil)
        }
    }
}

private struct VoiceEnvelope: Decodable {
    let voice: VoiceStudioMyVoice
    let creditsRemaining: Int

    enum CodingKeys: String, CodingKey {
        case voice
        case creditsRemaining = "credits_remaining"
    }
}

private struct DesignEnvelope: Decodable {
    struct Preview: Decodable {
        let generatedVoiceID: String
        let audioBase64: String
        let durationSecs: Double?

        enum CodingKeys: String, CodingKey {
            case generatedVoiceID = "generated_voice_id"
            case audioBase64 = "audio_base64"
            case durationSecs = "duration_secs"
        }
    }

    let previews: [Preview]
    let creditsRemaining: Int

    enum CodingKeys: String, CodingKey {
        case previews
        case creditsRemaining = "credits_remaining"
    }
}

private struct VoiceStudioErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String? }
    let error: Detail
    let costCredits: Int?

    enum CodingKeys: String, CodingKey {
        case error
        case costCredits = "cost_credits"
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
