import CryptoKit
import Foundation

enum VideoGenerationJobStatus: String, Codable, Equatable {
    case queued
    case rendering
    case completed
    case failed
}

struct VideoGenerationJob: Decodable, Equatable {
    let id: String
    let status: VideoGenerationJobStatus
    let progress: Double
    let creditsReserved: Int
    let refunded: Bool
    let resultURL: URL?
    let resultURLExpiresAt: Date?
    let assetID: String?
    let errorCode: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case status
        case progress
        case creditsReserved = "credits_reserved"
        case refunded
        case resultURL = "result_url"
        case resultURLExpiresAt = "result_url_expires_at"
        case assetID = "asset_id"
        case errorCode = "error_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct VideoGenerationJobEnvelope: Decodable, Equatable {
    let job: VideoGenerationJob
    let replayed: Bool?
}

struct VideoGenerationStartImage: Equatable {
    let mimeType: String
    let data: Data

    init(mimeType: String, data: Data) throws {
        let normalizedMIMEType = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedMIMEType == "image/jpeg", !data.isEmpty else {
            throw VideoGenerationServiceError.invalidStartImage
        }
        guard data.count <= VideoGenerationService.maxStartImageBytes else {
            throw VideoGenerationServiceError.startImageTooLarge
        }
        self.mimeType = normalizedMIMEType
        self.data = data
    }

    var requestPayload: [String: String] {
        [
            "mime_type": mimeType,
            "data_base64": data.base64EncodedString()
        ]
    }
}

enum VideoGenerationModel: String, CaseIterable, Identifiable {
    case seedance20Fast = "seedance-2.0-fast"
    case seedance15Pro = "seedance-1.5-pro"
    case automatic = "auto"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seedance20Fast:
            return "Seedance 2.0 Fast · официальный"
        case .seedance15Pro:
            return "Seedance 1.5 Pro"
        case .automatic:
            return "Авто"
        }
    }
}

enum VideoGenerationResolution: String, CaseIterable, Identifiable {
    case standard = "480p"
    case hd = "720p"
    case fullHD = "1080p"

    var id: String { rawValue }
    var title: String { rawValue }
}

enum VideoGenerationServiceError: LocalizedError, Equatable {
    case invalidPrompt
    case invalidAspectRatio
    case invalidDuration
    case invalidStartImage
    case startImageTooLarge
    case invalidJobID
    case missingAccessToken
    case transport
    case server(statusCode: Int, code: String?, message: String)
    case invalidResponse

    var makesJobUnavailable: Bool {
        guard case .server(_, let code, _) = self else {
            return false
        }
        switch code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "job_not_found",
             "job_access_denied",
             "job_not_owned",
             "not_owner",
             "ownership_mismatch":
            return true
        default:
            return false
        }
    }

    var requiresAuthenticationRefresh: Bool {
        guard case .server(let statusCode, _, _) = self else {
            return false
        }
        return statusCode == 401 || statusCode == 403
    }

    var errorDescription: String? {
        switch self {
        case .invalidPrompt:
            return "Опишите ролик хотя бы тремя символами."
        case .invalidAspectRatio:
            return "Выберите поддерживаемый формат ролика."
        case .invalidDuration:
            return "Выберите доступную длительность ролика."
        case .invalidStartImage:
            return "Не удалось подготовить выбранное изображение. Выберите другое фото."
        case .startImageTooLarge:
            return "Изображение слишком большое. Выберите фото меньшего размера."
        case .invalidJobID:
            return "Не удалось определить задачу генерации."
        case .missingAccessToken:
            return "Войдите в аккаунт и повторите попытку."
        case .transport:
            return "Нет связи с сервером генерации. Проверьте интернет и повторите попытку."
        case .server(_, let code, _):
            return Self.safeServerErrorDescription(code: code)
        case .invalidResponse:
            return "Сервер вернул некорректный ответ. Повторите попытку."
        }
    }

    private static func safeServerErrorDescription(code: String?) -> String {
        switch code {
        case "insufficient_credits":
            return "Недостаточно кредитов для генерации видео."
        case "content_rejected":
            return "Этот запрос не прошёл проверку безопасности. Измените описание."
        case "provider_unavailable":
            return "Сервис видео временно занят. Кредиты не списаны — попробуйте ещё раз."
        case "start_image_too_large":
            return "Изображение слишком большое. Выберите фото меньшего размера."
        case "unsupported_start_image":
            return "Не удалось обработать выбранное изображение. Выберите другое фото."
        default:
            return "Сервер не смог запустить генерацию. Повторите попытку."
        }
    }
}

final class VideoGenerationService {
    static let maxStartImageBytes = 8 * 1024 * 1024

    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String
    private let decoder: JSONDecoder

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey

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

    func submit(
        prompt: String,
        aspectRatio: String,
        durationSeconds: Int,
        model: VideoGenerationModel = .automatic,
        resolution: VideoGenerationResolution = .hd,
        generateAudio: Bool = false,
        idempotencyKey: String,
        startImage: VideoGenerationStartImage? = nil,
        accessToken: String
    ) async throws -> VideoGenerationJobEnvelope {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...2_500).contains(cleanPrompt.count) else {
            throw VideoGenerationServiceError.invalidPrompt
        }
        guard Self.supportedAspectRatios.contains(aspectRatio) else {
            throw VideoGenerationServiceError.invalidAspectRatio
        }
        guard Self.supportedDurations.contains(durationSeconds) else {
            throw VideoGenerationServiceError.invalidDuration
        }
        guard UUID(uuidString: idempotencyKey) != nil else {
            throw VideoGenerationServiceError.invalidJobID
        }

        let token = try validatedAccessToken(accessToken)
        let url = baseURL.appendingPathComponent("functions/v1/generate-video")
        var request = authorizedRequest(url: url, accessToken: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "idempotency_key": idempotencyKey,
            "prompt": cleanPrompt,
            "aspect_ratio": aspectRatio,
            "duration_seconds": durationSeconds,
            "model": model.rawValue,
            "resolution": resolution.rawValue,
            "generate_audio": generateAudio
        ]
        if let startImage {
            payload["start_image"] = startImage.requestPayload
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await perform(request)
    }

    func status(
        jobID: String,
        accessToken: String
    ) async throws -> VideoGenerationJobEnvelope {
        guard UUID(uuidString: jobID) != nil else {
            throw VideoGenerationServiceError.invalidJobID
        }
        let token = try validatedAccessToken(accessToken)

        var components = URLComponents(
            url: baseURL.appendingPathComponent("functions/v1/generate-video"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "job_id", value: jobID)]
        guard let url = components?.url else {
            throw VideoGenerationServiceError.invalidJobID
        }

        var request = authorizedRequest(url: url, accessToken: token)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validatedAccessToken(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw VideoGenerationServiceError.missingAccessToken
        }
        return clean
    }

    private func perform(_ request: URLRequest) async throws -> VideoGenerationJobEnvelope {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VideoGenerationServiceError.transport
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw VideoGenerationServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverError = (try? decoder.decode(VideoGenerationErrorEnvelope.self, from: data))?.error
            throw VideoGenerationServiceError.server(
                statusCode: http.statusCode,
                code: serverError?.code,
                message: Self.safeMessage(serverError?.message)
            )
        }

        do {
            return try decoder.decode(VideoGenerationJobEnvelope.self, from: data)
        } catch {
            throw VideoGenerationServiceError.invalidResponse
        }
    }

    private static func safeMessage(_ value: String?) -> String {
        let clean = (value ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(240))
    }

    private static let supportedAspectRatios: Set<String> = ["9:16", "16:9"]
    private static let supportedDurations: Set<Int> = [5, 10]
}

enum VideoGenerationInputFingerprint {
    static func make(
        prompt: String,
        aspectRatio: String,
        durationSeconds: Int,
        model: VideoGenerationModel = .automatic,
        resolution: VideoGenerationResolution = .hd,
        generateAudio: Bool = false,
        startImage: VideoGenerationStartImage?
    ) -> String {
        var canonical: [String: Any] = [
            "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "aspect_ratio": aspectRatio,
            "duration_seconds": durationSeconds,
            "model": model.rawValue,
            "resolution": resolution.rawValue,
            "generate_audio": generateAudio
        ]
        if let startImage {
            canonical["start_image"] = [
                "mime_type": startImage.mimeType,
                "sha256": sha256Hex(startImage.data)
            ]
        } else {
            canonical["start_image"] = NSNull()
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: canonical,
            options: [.sortedKeys]
        )) ?? Data()
        return sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum VideoGenerationPollingRetryPolicy {
    static func delaySeconds(attempt: Int) -> UInt64 {
        let boundedAttempt = min(max(attempt, 0), 3)
        return min(30, 4 << UInt64(boundedAttempt))
    }

    static func delayNanoseconds(attempt: Int) -> UInt64 {
        delaySeconds(attempt: attempt) * 1_000_000_000
    }
}

final class VideoGenerationLocalStore {
    static let maximumRecentJobCount = 8
    static let maximumPendingSubmissionCount = 8

    private struct PendingSubmission: Codable {
        let idempotencyKey: String
        let fingerprint: String
    }

    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "x5.video-generation.v1"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func recentJobIDs(userID: String) -> [String] {
        guard let recentJobsKey = accountKey(
            userID: userID,
            suffix: "recent-job-ids"
        ) else {
            return []
        }
        let stored = defaults.stringArray(forKey: recentJobsKey) ?? []
        var seen = Set<String>()
        return stored.filter {
            UUID(uuidString: $0) != nil && seen.insert($0).inserted
        }
        .prefix(Self.maximumRecentJobCount)
        .map { $0 }
    }

    func remember(jobID: String, userID: String) {
        guard
            UUID(uuidString: jobID) != nil,
            let recentJobsKey = accountKey(
                userID: userID,
                suffix: "recent-job-ids"
            )
        else {
            return
        }
        var ids = recentJobIDs(userID: userID).filter { $0 != jobID }
        ids.insert(jobID, at: 0)
        defaults.set(
            Array(ids.prefix(Self.maximumRecentJobCount)),
            forKey: recentJobsKey
        )
    }

    func remove(jobID: String, userID: String) {
        guard let recentJobsKey = accountKey(
            userID: userID,
            suffix: "recent-job-ids"
        ) else {
            return
        }
        let remaining = recentJobIDs(userID: userID).filter { $0 != jobID }
        if remaining.isEmpty {
            defaults.removeObject(forKey: recentJobsKey)
        } else {
            defaults.set(remaining, forKey: recentJobsKey)
        }
    }

    func pendingIdempotencyKey(
        for fingerprint: String,
        userID: String,
        forceNew: Bool = false
    ) -> String {
        guard let pendingSubmissionKey = accountKey(
            userID: userID,
            suffix: "pending-submission"
        ) else {
            return UUID().uuidString
        }

        var pendingSubmissions = loadPendingSubmissions(forKey: pendingSubmissionKey)
        persistPendingSubmissions(
            pendingSubmissions,
            forKey: pendingSubmissionKey
        )
        if !forceNew,
           let pending = pendingSubmissions.first(where: {
               $0.fingerprint == fingerprint
           }) {
            return pending.idempotencyKey
        }

        let pending = PendingSubmission(
            idempotencyKey: UUID().uuidString,
            fingerprint: fingerprint
        )
        pendingSubmissions.removeAll { $0.fingerprint == fingerprint }
        pendingSubmissions.insert(pending, at: 0)
        persistPendingSubmissions(
            Array(pendingSubmissions.prefix(Self.maximumPendingSubmissionCount)),
            forKey: pendingSubmissionKey
        )
        return pending.idempotencyKey
    }

    func clearPending(acceptedKey: String, userID: String) {
        guard let pendingSubmissionKey = accountKey(
            userID: userID,
            suffix: "pending-submission"
        ) else { return }

        var pendingSubmissions = loadPendingSubmissions(forKey: pendingSubmissionKey)
        pendingSubmissions.removeAll { $0.idempotencyKey == acceptedKey }
        persistPendingSubmissions(pendingSubmissions, forKey: pendingSubmissionKey)
    }

    private func loadPendingSubmissions(forKey key: String) -> [PendingSubmission] {
        guard let data = defaults.data(forKey: key) else { return [] }

        let decoded: [PendingSubmission]
        if let ledger = try? JSONDecoder().decode([PendingSubmission].self, from: data) {
            decoded = ledger
        } else if let legacy = try? JSONDecoder().decode(PendingSubmission.self, from: data) {
            decoded = [legacy]
        } else {
            defaults.removeObject(forKey: key)
            return []
        }

        var seenFingerprints = Set<String>()
        var seenKeys = Set<String>()
        let sanitized = decoded.filter { pending in
            !pending.fingerprint.isEmpty
                && UUID(uuidString: pending.idempotencyKey) != nil
                && seenFingerprints.insert(pending.fingerprint).inserted
                && seenKeys.insert(pending.idempotencyKey).inserted
        }
        return Array(sanitized.prefix(Self.maximumPendingSubmissionCount))
    }

    private func persistPendingSubmissions(
        _ pendingSubmissions: [PendingSubmission],
        forKey key: String
    ) {
        let bounded = Array(
            pendingSubmissions.prefix(Self.maximumPendingSubmissionCount)
        )
        guard !bounded.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let encoded = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(encoded, forKey: key)
    }

    private func accountKey(userID: String, suffix: String) -> String? {
        let cleanUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountID = UUID(uuidString: cleanUserID) else {
            return nil
        }
        return "\(keyPrefix).\(accountID.uuidString.lowercased()).\(suffix)"
    }
}

private struct VideoGenerationErrorEnvelope: Decodable {
    let error: VideoGenerationServerError?
}

private struct VideoGenerationServerError: Decodable {
    let code: String?
    let message: String?
}
