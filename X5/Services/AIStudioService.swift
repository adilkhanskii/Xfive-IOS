import Foundation

struct AIStudioToolCapability: Decodable, Equatable {
    let available: Bool
    let unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case available
        case unavailableReason = "unavailable_reason"
    }
}

struct AIStudioCapabilities: Decodable, Equatable {
    struct ModelOption: Decodable, Equatable {
        let id: String
        let provider: String
    }

    struct Models: Decodable, Equatable {
        let image: [ModelOption]
        let voice: [ModelOption]
        let video: [ModelOption]
        let lipsync: [ModelOption]
    }

    struct Prices: Decodable, Equatable {
        let imageFrame: Int
        let voicePerStarted1000Characters: Int
        let video: [String: Int]
        let lipsyncPerSecond: Int

        enum CodingKeys: String, CodingKey {
            case imageFrame = "image_frame"
            case voicePerStarted1000Characters = "voice_per_started_1000_characters"
            case video
            case lipsyncPerSecond = "lipsync_per_second"
        }
    }

    let prices: Prices
    let models: Models
    let tools: [String: AIStudioToolCapability]

    func tool(_ id: String) -> AIStudioToolCapability {
        tools[id] ?? AIStudioToolCapability(available: false, unavailableReason: "unknown_tool")
    }

    func supportsImageModel(_ id: String) -> Bool {
        models.image.contains { $0.id == id }
    }
}

struct AIStudioAsset: Decodable, Identifiable, Hashable {
    let id: String
    let assetType: String
    let mimeType: String?
    let category: String?
    let title: String?
    let provider: String?
    let model: String?
    let durationSeconds: Double?
    let url: URL
    let urlExpiresAt: Date?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case assetType = "asset_type"
        case mimeType = "mime_type"
        case category
        case title
        case provider
        case model
        case durationSeconds = "duration_seconds"
        case url
        case urlExpiresAt = "url_expires_at"
        case createdAt = "created_at"
    }
}

struct AIStudioCharacter: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let characterKind: String
    let gender: String?
    let age: Int?
    let origin: String?
    let faceDescription: String?
    let bodyDescription: String?
    let skinDescription: String?
    let hairDescription: String?
    let outfitDescription: String?
    let accessoriesDescription: String?
    let extraDescription: String?
    let imageModel: String
    let approvedImageAssetID: String?
    let voiceID: String?
    let voiceLanguage: String?
    let voiceSpeed: Double?
    let approvedVoiceAssetID: String?
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, name, gender, age, origin, status
        case characterKind = "character_kind"
        case faceDescription = "face_description"
        case bodyDescription = "body_description"
        case skinDescription = "skin_description"
        case hairDescription = "hair_description"
        case outfitDescription = "outfit_description"
        case accessoriesDescription = "accessories_description"
        case extraDescription = "extra_description"
        case imageModel = "image_model"
        case approvedImageAssetID = "approved_image_asset_id"
        case voiceID = "voice_id"
        case voiceLanguage = "voice_language"
        case voiceSpeed = "voice_speed"
        case approvedVoiceAssetID = "approved_voice_asset_id"
    }
}

struct AIStudioPreset: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let toolID: String
    let settings: [String: String]
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, settings
        case toolID = "tool_id"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        toolID = try container.decode(String.self, forKey: .toolID)
        settings = try container.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct AIStudioAsyncJob: Decodable, Identifiable, Equatable {
    let id: String
    let status: String
    let progress: Double
    let costCredits: Int?
    let creditsRemaining: Int?
    let resultAssetID: String?
    let resultURL: URL?
    let resultURLExpiresAt: Date?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case id, status, progress
        case costCredits = "cost_credits"
        case creditsRemaining = "credits_remaining"
        case resultAssetID = "result_asset_id"
        case resultURL = "result_url"
        case resultURLExpiresAt = "result_url_expires_at"
        case errorCode = "error_code"
    }

    var isTerminal: Bool {
        ["completed", "failed", "refunded"].contains(status)
    }
}

enum AIStudioServiceError: LocalizedError, Equatable {
    case notAuthenticated
    case invalidResponse
    case server(status: Int, code: String?, message: String?, retryable: Bool)
    case transport

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Войдите в аккаунт и повторите попытку."
        case .invalidResponse:
            return "Сервер вернул некорректный ответ."
        case .transport:
            return "Нет связи с сервером. Проверьте интернет и повторите попытку."
        case .server(_, let code, let message, _):
            if let message, !message.isEmpty { return message }
            switch code {
            case "provider_not_configured", "lipsync_not_configured":
                return "Сервис временно недоступен: провайдер не подключён."
            case "insufficient_credits":
                return "Недостаточно кредитов."
            case "character_not_ready":
                return "Сначала подтвердите изображение и тест голоса персонажа."
            default:
                return "Сервис временно недоступен. Кредиты не потеряются."
            }
        }
    }
}

final class AIStudioService {
    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let regular = ISO8601DateFormatter()
            regular.formatOptions = [.withInternetDateTime]
            if let date = regular.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        self.decoder = decoder
    }

    func capabilities(accessToken: String) async throws -> AIStudioCapabilities {
        try await request(function: "ai-capabilities", accessToken: accessToken)
    }

    func assets(type: String? = nil, accessToken: String) async throws -> [AIStudioAsset] {
        let suffix = type.map { "?asset_type=\($0)&limit=80" } ?? "?limit=80"
        let envelope: AssetEnvelope = try await request(
            function: "ai-assets\(suffix)",
            accessToken: accessToken
        )
        return envelope.assets
    }

    func uploadAsset(
        data: Data,
        mimeType: String,
        assetType: String,
        title: String,
        accessToken: String
    ) async throws -> AIStudioAsset {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else {
            throw AIStudioServiceError.server(
                status: 413,
                code: "media_too_large",
                message: "Файл должен быть не больше 8 МБ.",
                retryable: false
            )
        }
        let envelope: SingleAssetEnvelope = try await request(
            function: "ai-assets",
            method: "POST",
            body: [
                "data_base64": data.base64EncodedString(),
                "mime_type": mimeType,
                "asset_type": assetType,
                "title": String(title.prefix(120))
            ],
            accessToken: accessToken
        )
        return envelope.asset
    }

    func characters(accessToken: String) async throws -> [AIStudioCharacter] {
        let envelope: CharacterEnvelope = try await request(
            function: "ai-character",
            accessToken: accessToken
        )
        return envelope.characters
    }

    func createCharacter(
        fields: [String: Any],
        accessToken: String
    ) async throws -> AIStudioCharacter {
        let envelope: SingleCharacterEnvelope = try await request(
            function: "ai-character",
            method: "POST",
            body: ["action": "create", "character": fields],
            accessToken: accessToken
        )
        return envelope.character
    }

    func approveCharacterImage(
        characterID: String,
        assetID: String,
        accessToken: String
    ) async throws -> AIStudioCharacter {
        let envelope: SingleCharacterEnvelope = try await request(
            function: "ai-character",
            method: "POST",
            body: [
                "action": "approve_image",
                "character_id": characterID,
                "asset_id": assetID
            ],
            accessToken: accessToken
        )
        return envelope.character
    }

    func approveCharacterVoice(
        characterID: String,
        assetID: String,
        voice: VoiceGenerationVoice,
        language: String,
        speed: Double,
        accessToken: String
    ) async throws -> AIStudioCharacter {
        let envelope: SingleCharacterEnvelope = try await request(
            function: "ai-character",
            method: "POST",
            body: [
                "action": "approve_voice",
                "character_id": characterID,
                "asset_id": assetID,
                "voice_id": voice.rawValue,
                "language": language,
                "speed": speed
            ],
            accessToken: accessToken
        )
        return envelope.character
    }

    func presets(accessToken: String) async throws -> [AIStudioPreset] {
        let envelope: PresetEnvelope = try await request(
            function: "ai-presets",
            accessToken: accessToken
        )
        return envelope.presets
    }

    func savePreset(
        name: String,
        toolID: String,
        settings: [String: String],
        accessToken: String
    ) async throws -> AIStudioPreset {
        let envelope: SinglePresetEnvelope = try await request(
            function: "ai-presets",
            method: "POST",
            body: [
                "action": "save",
                "name": name,
                "tool_id": toolID,
                "settings": settings
            ],
            accessToken: accessToken
        )
        return envelope.preset
    }

    func deletePreset(id: String, accessToken: String) async throws {
        let _: EmptyEnvelope = try await request(
            function: "ai-presets",
            method: "POST",
            body: ["action": "delete", "id": id],
            accessToken: accessToken
        )
    }

    func startLipsync(
        videoAssetID: String,
        audioAssetID: String,
        durationSeconds: Int,
        requestID: String,
        accessToken: String
    ) async throws -> AIStudioAsyncJob {
        let envelope: JobEnvelope = try await request(
            function: "generate-lipsync",
            method: "POST",
            body: [
                "request_id": requestID,
                "video_asset_id": videoAssetID,
                "audio_asset_id": audioAssetID,
                "duration_seconds": durationSeconds
            ],
            accessToken: accessToken,
            acceptedStatuses: 200..<300
        )
        return envelope.job
    }

    func lipsyncJob(id: String, accessToken: String) async throws -> AIStudioAsyncJob {
        let envelope: JobEnvelope = try await request(
            function: "generate-lipsync?job_id=\(id)",
            accessToken: accessToken,
            acceptedStatuses: 200..<300
        )
        return envelope.job
    }

    func startInfluencer(
        characterID: String,
        scene: String,
        speechText: String,
        aspectRatio: String,
        durationSeconds: Int,
        requestID: String,
        accessToken: String
    ) async throws -> AIStudioAsyncJob {
        let envelope: JobEnvelope = try await request(
            function: "generate-influencer-video",
            method: "POST",
            body: [
                "request_id": requestID,
                "character_id": characterID,
                "scene": scene,
                "speech_text": speechText,
                "aspect_ratio": aspectRatio,
                "duration_seconds": durationSeconds
            ],
            accessToken: accessToken,
            acceptedStatuses: 200..<300
        )
        return envelope.job
    }

    func influencerJob(id: String, accessToken: String) async throws -> AIStudioAsyncJob {
        let envelope: JobEnvelope = try await request(
            function: "generate-influencer-video?job_id=\(id)",
            accessToken: accessToken,
            acceptedStatuses: 200..<300
        )
        return envelope.job
    }

    private func request<T: Decodable>(
        function: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        accessToken: String,
        acceptedStatuses: Range<Int> = 200..<300
    ) async throws -> T {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AIStudioServiceError.notAuthenticated }
        guard let url = URL(string: "\(baseURL.absoluteString)/functions/v1/\(function)") else {
            throw AIStudioServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 240
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIStudioServiceError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIStudioServiceError.invalidResponse
        }
        guard acceptedStatuses.contains(http.statusCode) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw AIStudioServiceError.server(
                status: http.statusCode,
                code: envelope?.error?.code ?? envelope?.errorCode,
                message: envelope?.error?.message ?? envelope?.message,
                retryable: envelope?.error?.retryable ?? false
            )
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AIStudioServiceError.invalidResponse
        }
    }
}

private struct AssetEnvelope: Decodable { let assets: [AIStudioAsset] }
private struct SingleAssetEnvelope: Decodable { let asset: AIStudioAsset }
private struct CharacterEnvelope: Decodable { let characters: [AIStudioCharacter] }
private struct SingleCharacterEnvelope: Decodable { let character: AIStudioCharacter }
private struct PresetEnvelope: Decodable { let presets: [AIStudioPreset] }
private struct SinglePresetEnvelope: Decodable { let preset: AIStudioPreset }
private struct JobEnvelope: Decodable { let job: AIStudioAsyncJob }
private struct EmptyEnvelope: Decodable {
    init(from decoder: Decoder) throws { }
}

private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: String?
        let message: String?
        let retryable: Bool?
    }
    let error: Detail?
    let errorCode: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case error, message
        case errorCode = "error_code"
    }
}
