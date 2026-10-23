import Foundation
import CryptoKit
import UIKit

struct FruitStoryQuestionnaire: Encodable, Equatable {
    var fruit: String
    var personality: String
    var goal: String
    var location: String
    var event: String
    var ending: String
    var aspectRatio: String = "9:16"

    enum CodingKeys: String, CodingKey {
        case fruit
        case personality
        case goal
        case location
        case event
        case ending
        case aspectRatio = "aspect_ratio"
    }

    static let preview = FruitStoryQuestionnaire(
        fruit: "Манго",
        personality: "Дерзкий и добрый",
        goal: "Познакомить гостей с новым напитком",
        location: "Летнее кафе",
        event: "Готовит лимонад",
        ending: "Подмигивает зрителю"
    )
}

struct FruitStoryScene: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var visualPrompt: String
    var action: String
    var camera: String
    var caption: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case visualPrompt = "visual_prompt"
        case action
        case camera
        case caption
    }
}

struct FruitStory: Codable, Equatable {
    var title: String
    var summary: String
    var characterBible: String
    var finalVideoPrompt: String
    var scenes: [FruitStoryScene]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case characterBible = "character_bible"
        case finalVideoPrompt = "final_video_prompt"
        case scenes
    }
}

struct FruitStoryEnvelope: Codable, Equatable {
    let requestID: UUID
    let replayed: Bool
    let story: FruitStory

    enum CodingKeys: String, CodingKey {
        case story
        case requestID = "request_id"
        case replayed
    }

    static let preview = FruitStoryEnvelope(
        requestID: UUID(
            uuidString: "10000000-0000-4000-8000-000000000001"
        )!,
        replayed: false,
        story: FruitStory(
            title: "Манго открывает кафе",
            summary: "Один герой проходит три короткие сцены.",
            characterBible: "Один манго с круглыми глазами и синей бабочкой.",
            finalVideoPrompt: "Вертикальная кинематографичная история об одном фрукте.",
            scenes: [
                FruitStoryScene(
                    id: "scene-1",
                    title: "Знакомство",
                    visualPrompt: "Манго входит в летнее кафе",
                    action: "Открывает дверь",
                    camera: "Общий план",
                    caption: "Начинаем"
                ),
                FruitStoryScene(
                    id: "scene-2",
                    title: "Напиток",
                    visualPrompt: "Тот же манго готовит лимонад",
                    action: "Смешивает напиток",
                    camera: "Средний план",
                    caption: "Свежий вкус"
                ),
                FruitStoryScene(
                    id: "scene-3",
                    title: "Финал",
                    visualPrompt: "Тот же манго подмигивает зрителю",
                    action: "Подмигивает",
                    camera: "Крупный план",
                    caption: "Попробуй сегодня"
                ),
            ]
        )
    )
}

enum FruitStoryServiceError: LocalizedError, Equatable {
    case invalidQuestionnaire
    case missingAccessToken
    case contentRejected
    case outcomeUnknown
    case transport
    case serverUnavailable
    case invalidStory

    var errorDescription: String? {
        switch self {
        case .invalidQuestionnaire:
            return "Заполните все поля и укажите ровно один фрукт."
        case .missingAccessToken:
            return "Войдите в аккаунт и повторите попытку."
        case .contentRejected:
            return "Запрос не прошёл проверку безопасности. Измените описание."
        case .outcomeUnknown:
            return "Запрос не завершился. Нажмите «Создать раскадровку» ещё раз: продолжится тот же запрос без повторного списания."
        case .transport:
            return "Нет связи с сервисом историй. Проверьте интернет и повторите попытку."
        case .serverUnavailable:
            return "Сервис историй временно недоступен. Попробуйте позже."
        case .invalidStory:
            return "Не удалось получить готовую историю из трёх сцен. Повторите попытку."
        }
    }
}

final class FruitStoryService {
    private let session: URLSession
    private let baseURL: URL
    private let anonKey: String
    private let recoveryDelayNanoseconds: UInt64
    private let maximumRecoveryAttempts: Int

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        anonKey: String = X5Config.supabaseAnonKey,
        recoveryDelayNanoseconds: UInt64 = 3_000_000_000,
        maximumRecoveryAttempts: Int = 2
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.recoveryDelayNanoseconds = recoveryDelayNanoseconds
        self.maximumRecoveryAttempts = max(0, maximumRecoveryAttempts)
    }

    func generate(
        questionnaire: FruitStoryQuestionnaire,
        requestID: UUID,
        accessToken: String
    ) async throws -> FruitStoryEnvelope {
        guard Self.isValid(questionnaire) else {
            throw FruitStoryServiceError.invalidQuestionnaire
        }
        let cleanToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            throw FruitStoryServiceError.missingAccessToken
        }

        let url = baseURL.appendingPathComponent("functions/v1/fruit-story")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            FruitStoryRequest(
                requestID: requestID,
                questionnaire: questionnaire
            )
        )

        for attempt in 0...maximumRecoveryAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < maximumRecoveryAttempts else {
                    throw FruitStoryServiceError.transport
                }
                try await Task.sleep(nanoseconds: recoveryDelayNanoseconds)
                continue
            }

            guard let http = response as? HTTPURLResponse else {
                throw FruitStoryServiceError.transport
            }
            guard (200..<300).contains(http.statusCode) else {
                let serviceError = Self.safeError(
                    statusCode: http.statusCode,
                    data: data
                )
                let safeCode = (try? JSONDecoder().decode(
                    SafeErrorEnvelope.self,
                    from: data
                ))?.error.code
                let recoverable = http.statusCode == 425
                    || http.statusCode == 429
                    || safeCode == "outcome_unknown"
                    || safeCode == "in_progress"
                    || safeCode == "rate_limited"
                guard recoverable, attempt < maximumRecoveryAttempts else {
                    throw serviceError
                }
                try await Task.sleep(nanoseconds: recoveryDelayNanoseconds)
                continue
            }
            guard let envelope = try? JSONDecoder().decode(FruitStoryEnvelope.self, from: data),
                  envelope.requestID == requestID,
                  Self.isValid(envelope.story)
            else {
                throw FruitStoryServiceError.invalidStory
            }
            return envelope
        }
        throw FruitStoryServiceError.serverUnavailable
    }

    private static func isValid(_ questionnaire: FruitStoryQuestionnaire) -> Bool {
        let fields = [
            questionnaire.fruit,
            questionnaire.personality,
            questionnaire.goal,
            questionnaire.location,
            questionnaire.event,
            questionnaire.ending,
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let fruit = fields[0]
        let separators = [",", ";", "/", "\\", "&", "\n", " и "]
        return questionnaire.aspectRatio == "9:16"
            && !fruit.isEmpty
            && fruit.count <= 80
            && fields.dropFirst().allSatisfy { !$0.isEmpty && $0.count <= 400 }
            && !separators.contains { fruit.localizedCaseInsensitiveContains($0) }
    }

    private static func isValid(_ story: FruitStory) -> Bool {
        guard story.scenes.count == 3,
              !story.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !story.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !story.characterBible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !story.finalVideoPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        return Set(story.scenes.map(\.id)).count == 3
            && story.scenes.allSatisfy { scene in
            !scene.id.isEmpty
                && !scene.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !scene.visualPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !scene.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !scene.camera.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !scene.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func safeError(statusCode: Int, data: Data) -> FruitStoryServiceError {
        if statusCode == 401 {
            return .missingAccessToken
        }
        if let payload = try? JSONDecoder().decode(SafeErrorEnvelope.self, from: data),
           payload.error.code == "content_rejected" {
            return .contentRejected
        }
        if let payload = try? JSONDecoder().decode(SafeErrorEnvelope.self, from: data),
           payload.error.code == "outcome_unknown" {
            return .outcomeUnknown
        }
        return .serverUnavailable
    }
}

private struct FruitStoryRequest: Encodable {
    let requestID: UUID
    let questionnaire: FruitStoryQuestionnaire

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case fruit
        case personality
        case goal
        case location
        case event
        case ending
        case aspectRatio = "aspect_ratio"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            requestID.uuidString.lowercased(),
            forKey: .requestID
        )
        try container.encode(questionnaire.fruit, forKey: .fruit)
        try container.encode(
            questionnaire.personality,
            forKey: .personality
        )
        try container.encode(questionnaire.goal, forKey: .goal)
        try container.encode(questionnaire.location, forKey: .location)
        try container.encode(questionnaire.event, forKey: .event)
        try container.encode(questionnaire.ending, forKey: .ending)
        try container.encode(
            questionnaire.aspectRatio,
            forKey: .aspectRatio
        )
    }
}

enum FruitStoryQuestionnaireFingerprint {
    static func make(_ questionnaire: FruitStoryQuestionnaire) -> String {
        let fields = [
            questionnaire.fruit,
            questionnaire.personality,
            questionnaire.goal,
            questionnaire.location,
            questionnaire.event,
            questionnaire.ending,
            questionnaire.aspectRatio,
        ].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
        }
        let canonical = fields.map {
            "\($0.utf16.count):\($0)"
        }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct FruitStoryPendingRequest: Codable, Equatable {
    let requestID: UUID
    let fingerprint: String
}

final class FruitStoryPendingRequestStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "x5.live-fruits.story.pending.v1"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func pending(userID: String) -> FruitStoryPendingRequest? {
        guard let key = accountKey(userID: userID),
              let data = defaults.data(forKey: key),
              let pending = try? JSONDecoder().decode(
                FruitStoryPendingRequest.self,
                from: data
              ),
              !pending.fingerprint.isEmpty
        else {
            return nil
        }
        return pending
    }

    func requestID(userID: String, fingerprint: String) -> UUID {
        guard let key = accountKey(userID: userID) else {
            return UUID()
        }
        if let existing = pending(userID: userID),
           existing.fingerprint == fingerprint {
            return existing.requestID
        }

        let value = FruitStoryPendingRequest(
            requestID: UUID(),
            fingerprint: fingerprint
        )
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
        return value.requestID
    }

    func clear(userID: String, requestID: UUID) {
        guard let key = accountKey(userID: userID),
              pending(userID: userID)?.requestID == requestID
        else {
            return
        }
        defaults.removeObject(forKey: key)
    }

    private func accountKey(userID: String) -> String? {
        let clean = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountID = UUID(uuidString: clean) else {
            return nil
        }
        return "\(keyPrefix).\(accountID.uuidString.lowercased())"
    }
}

enum LiveFruitsImageRequestFingerprint {
    static func make(
        prompt: String,
        provider: ImageGenerationProvider,
        category: ImageGenerationCategory,
        quantity: Int,
        size: ImageGenerationSize,
        referenceImages: [ImageGenerationReference]
    ) -> String {
        let normalizedPrompt = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceDigests = referenceImages.map { reference in
            let mimeType = reference.mimeType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let encoded = reference.base64
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let digest = SHA256.hash(data: Data(encoded.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "\(mimeType):\(digest)"
        }
        let components = [
            provider.provider,
            provider.rawValue,
            category.id,
            String(quantity),
            size.rawValue,
            normalizedPrompt,
            String(referenceDigests.count),
        ] + referenceDigests
        let canonical = components.map {
            "\($0.utf8.count):\($0)"
        }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct LiveFruitsImagePendingRequest: Codable, Equatable {
    let requestID: String
    let fingerprint: String
}

final class LiveFruitsImagePendingRequestStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "x5.live-fruits.image.pending.v1"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func pending(
        userID: String,
        slot: String
    ) -> LiveFruitsImagePendingRequest? {
        let cleanSlot = normalizedSlot(slot)
        guard !cleanSlot.isEmpty else { return nil }
        return entries(userID: userID)[cleanSlot]
    }

    func requestID(
        userID: String,
        slot: String,
        fingerprint: String
    ) -> String {
        let cleanSlot = normalizedSlot(slot)
        let cleanFingerprint = fingerprint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let key = accountKey(userID: userID),
              !cleanSlot.isEmpty,
              !cleanFingerprint.isEmpty
        else {
            return UUID().uuidString.lowercased()
        }

        var values = entries(userID: userID)
        if let existing = values[cleanSlot],
           existing.fingerprint == cleanFingerprint,
           UUID(uuidString: existing.requestID) != nil {
            return existing.requestID
        }

        let value = LiveFruitsImagePendingRequest(
            requestID: UUID().uuidString.lowercased(),
            fingerprint: cleanFingerprint
        )
        values[cleanSlot] = value
        persist(values, key: key)
        return value.requestID
    }

    func clear(
        userID: String,
        slot: String,
        fingerprint: String,
        requestID: String
    ) {
        let cleanSlot = normalizedSlot(slot)
        guard let key = accountKey(userID: userID),
              !cleanSlot.isEmpty
        else {
            return
        }

        var values = entries(userID: userID)
        guard let existing = values[cleanSlot],
              existing.fingerprint == fingerprint,
              existing.requestID == requestID
        else {
            return
        }
        values.removeValue(forKey: cleanSlot)
        persist(values, key: key)
    }

    private func entries(
        userID: String
    ) -> [String: LiveFruitsImagePendingRequest] {
        guard let key = accountKey(userID: userID),
              let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode(
                [String: LiveFruitsImagePendingRequest].self,
                from: data
              )
        else {
            return [:]
        }
        return values.filter {
            !$0.key.isEmpty
                && !$0.value.fingerprint.isEmpty
                && UUID(uuidString: $0.value.requestID) != nil
        }
    }

    private func persist(
        _ values: [String: LiveFruitsImagePendingRequest],
        key: String
    ) {
        guard !values.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }

    private func normalizedSlot(_ slot: String) -> String {
        slot.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func accountKey(userID: String) -> String? {
        let clean = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountID = UUID(uuidString: clean) else {
            return nil
        }
        return "\(keyPrefix).\(accountID.uuidString.lowercased())"
    }
}

private struct SafeErrorEnvelope: Decodable {
    struct SafeError: Decodable {
        let code: String
    }

    let error: SafeError
}

enum FruitStoryFrameRegeneration {
    static func replacingFrame(
        sceneID: String,
        imageBase64: String,
        in currentFrames: [String: String]
    ) -> [String: String] {
        var updatedFrames = currentFrames
        updatedFrames[sceneID] = imageBase64
        return updatedFrames
    }
}

enum FruitStoryStartImagePreparer {
    static let targetPixelSize = CGSize(width: 720, height: 1_280)
    private static let compressionQualities: [CGFloat] = [
        0.88,
        0.76,
        0.64,
        0.50,
        0.38,
    ]

    static func makeStartImage(
        from source: UIImage
    ) throws -> VideoGenerationStartImage {
        guard source.size.width > 0, source.size.height > 0 else {
            throw VideoGenerationServiceError.invalidStartImage
        }

        let frame = centerCroppedFrame(from: source)
        guard let pixels = frame.cgImage,
              pixels.width * 16 == pixels.height * 9
        else {
            throw VideoGenerationServiceError.invalidStartImage
        }
        for quality in compressionQualities {
            guard let data = frame.jpegData(compressionQuality: quality) else {
                throw VideoGenerationServiceError.invalidStartImage
            }
            if data.count <= VideoGenerationService.maxStartImageBytes {
                return try VideoGenerationStartImage(
                    mimeType: "image/jpeg",
                    data: data
                )
            }
        }
        throw VideoGenerationServiceError.startImageTooLarge
    }

    private static func centerCroppedFrame(from source: UIImage) -> UIImage {
        let widthScale = targetPixelSize.width / source.size.width
        let heightScale = targetPixelSize.height / source.size.height
        let fillScale = max(widthScale, heightScale)
        let drawSize = CGSize(
            width: source.size.width * fillScale,
            height: source.size.height * fillScale
        )
        let drawRect = CGRect(
            x: (targetPixelSize.width - drawSize.width) / 2,
            y: (targetPixelSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: targetPixelSize,
            format: format
        ).image { _ in
            source.draw(in: drawRect)
        }
    }
}

enum FruitStoryVideoPromptBuilder {
    static func makePrompt(story: FruitStory, scenes: [FruitStoryScene]) -> String {
        let orderedScenes = scenes.prefix(3).enumerated().map { index, scene in
            """
            \(index + 1). \(clipped(scene.title, to: 60))
            Кадр: \(clipped(scene.visualPrompt, to: 160))
            Действие: \(clipped(scene.action, to: 80))
            Камера: \(clipped(scene.camera, to: 60))
            Надпись: \(clipped(scene.caption, to: 60))
            """
        }.joined(separator: "\n\n")

        return """
        Вертикальный ролик 9:16 продолжительностью 10 секунд для Xfive marketing.
        Один главный фрукт остаётся визуально идентичным во всех кадрах.
        Паспорт персонажа: \(clipped(story.characterBible, to: 240))
        Сюжет: \(clipped(story.summary, to: 140))

        \(orderedScenes)

        Основа финального промпта: \(clipped(story.finalVideoPrompt, to: 140))
        Без дополнительных фруктов и без смены внешности главного персонажа.
        """
    }

    private static func clipped(_ value: String, to maximum: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
    }
}
