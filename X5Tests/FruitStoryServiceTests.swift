import Foundation
import UIKit
import XCTest
@testable import X5

final class FruitStoryServiceTests: XCTestCase {
    func testGenerateUsesAuthenticatedStoryEndpointAndSnakeCasePayload() async throws {
        let recorder = FruitStoryRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 200),
                Data(Self.validStoryJSON.utf8)
            )
        }

        let result = try await service.generate(
            questionnaire: FruitStoryQuestionnaire(
                fruit: "Манго",
                personality: "Дерзкий",
                goal: "Реклама",
                location: "Кафе",
                event: "Готовит лимонад",
                ending: "Подмигивает",
                aspectRatio: "9:16"
            ),
            requestID: UUID(
                uuidString: "11111111-1111-4111-8111-111111111111"
            )!,
            accessToken: "access-token"
        )

        XCTAssertEqual(result.story.scenes.count, 3)
        XCTAssertEqual(
            result.requestID,
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/functions/v1/fruit-story")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(payload["aspect_ratio"] as? String, "9:16")
        XCTAssertEqual(payload["fruit"] as? String, "Манго")
        XCTAssertEqual(
            payload["request_id"] as? String,
            "11111111-1111-4111-8111-111111111111"
        )
    }

    func testDecodeRejectsStoryWithoutExactlyThreeScenes() async throws {
        let recorder = FruitStoryRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            let invalid = Self.validStoryJSON.replacingOccurrences(
                of: #",{"id":"scene-3","title":"Финал","visual_prompt":"Тот же манго подмигивает","action":"Подмигивает","camera":"Крупный план","caption":"Попробуй сегодня"}"#,
                with: ""
            )
            return (Self.response(for: request, statusCode: 200), Data(invalid.utf8))
        }

        do {
            _ = try await service.generate(
                questionnaire: .preview,
                requestID: UUID(
                    uuidString: "22222222-2222-4222-8222-222222222222"
                )!,
                accessToken: "access-token"
            )
            XCTFail("Expected invalid story")
        } catch {
            XCTAssertEqual(error as? FruitStoryServiceError, .invalidStory)
        }
    }

    func testDecodeRejectsResponseForAnotherRequest() async throws {
        let recorder = FruitStoryRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 200),
                Data(Self.validStoryJSON.utf8)
            )
        }

        do {
            _ = try await service.generate(
                questionnaire: .preview,
                requestID: UUID(
                    uuidString: "33333333-3333-4333-8333-333333333333"
                )!,
                accessToken: "access-token"
            )
            XCTFail("Expected mismatched response to be rejected")
        } catch {
            XCTAssertEqual(error as? FruitStoryServiceError, .invalidStory)
        }
    }

    func testAmbiguousProviderOutcomeHasExplicitSafeError() async throws {
        let recorder = FruitStoryRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 409),
                Data(#"{"error":{"code":"outcome_unknown"}}"#.utf8)
            )
        }

        do {
            _ = try await service.generate(
                questionnaire: .preview,
                requestID: UUID(
                    uuidString: "44444444-4444-4444-8444-444444444444"
                )!,
                accessToken: "access-token"
            )
            XCTFail("Expected outcome unknown")
        } catch {
            XCTAssertEqual(error as? FruitStoryServiceError, .outcomeUnknown)
        }
    }

    func testAmbiguousProviderOutcomeRetriesTheSameRequestAndRecovers() async throws {
        let recorder = FruitStoryRequestRecorder()
        var attempts = 0
        let service = makeService(recorder: recorder) { request in
            attempts += 1
            if attempts == 1 {
                return (
                    Self.response(for: request, statusCode: 409),
                    Data(#"{"error":{"code":"outcome_unknown"}}"#.utf8)
                )
            }
            return (
                Self.response(for: request, statusCode: 200),
                Data(Self.validStoryJSON.utf8)
            )
        }

        let requestID = UUID(
            uuidString: "11111111-1111-4111-8111-111111111111"
        )!
        let result = try await service.generate(
            questionnaire: .preview,
            requestID: requestID,
            accessToken: "access-token"
        )

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(result.requestID, requestID)
        XCTAssertEqual(result.story.scenes.count, 3)
    }

    func testVideoPromptUsesCurrentStoryboardOrderAndEdits() {
        let story = FruitStoryEnvelope.preview.story
        let reordered = [
            story.scenes[2],
            FruitStoryScene(
                id: "scene-2",
                title: "Новая середина",
                visualPrompt: "Новый кадр",
                action: "Танцует",
                camera: "Плавный облет",
                caption: "Новый текст"
            ),
            story.scenes[0],
        ]

        let prompt = FruitStoryVideoPromptBuilder.makePrompt(
            story: story,
            scenes: reordered
        )

        XCTAssertLessThan(
            try XCTUnwrap(prompt.range(of: "1. Финал")?.lowerBound),
            try XCTUnwrap(prompt.range(of: "2. Новая середина")?.lowerBound)
        )
        XCTAssertTrue(prompt.contains("Один главный фрукт"))
        XCTAssertTrue(prompt.contains("9:16"))
    }

    func testLiveFruitsStartImageIsExactNineBySixteenJPEGAndWithinLimit() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 1_024, height: 1_536),
            format: format
        ).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 1_536))
        }

        let prepared = try FruitStoryStartImagePreparer.makeStartImage(
            from: source
        )
        let decoded = try XCTUnwrap(UIImage(data: prepared.data))
        let pixels = try XCTUnwrap(decoded.cgImage)

        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(pixels.width, 720)
        XCTAssertEqual(pixels.height, 1_280)
        XCTAssertEqual(pixels.width * 16, pixels.height * 9)
        XCTAssertLessThanOrEqual(
            prepared.data.count,
            VideoGenerationService.maxStartImageBytes
        )
    }

    func testReplacingOneSceneFramePreservesTheOtherGeneratedFrames() {
        let current = [
            "scene-1": "frame-one",
            "scene-2": "frame-two",
            "scene-3": "frame-three",
        ]

        let updated = FruitStoryFrameRegeneration.replacingFrame(
            sceneID: "scene-2",
            imageBase64: "frame-two-regenerated",
            in: current
        )

        XCTAssertEqual(updated["scene-1"], "frame-one")
        XCTAssertEqual(updated["scene-2"], "frame-two-regenerated")
        XCTAssertEqual(updated["scene-3"], "frame-three")
        XCTAssertEqual(updated.count, 3)
        XCTAssertEqual(current["scene-2"], "frame-two")
    }

    func testFrameLedgerPreservesReorderedFramesAndInvalidatesOnlyEditedScene() {
        let original = FruitStoryEnvelope.preview.story.scenes
        let frames = [
            original[0].id: "frame-one",
            original[1].id: "frame-two",
            original[2].id: "frame-three",
        ]
        let fingerprints = Dictionary(
            uniqueKeysWithValues: original.map {
                ($0.id, LiveFruitsFrameLedger.visualFingerprint(for: $0))
            }
        )

        let reordered = [original[2], original[0], original[1]]
        let reorderedLedger = LiveFruitsFrameLedger.reconciled(
            scenes: reordered,
            frames: frames,
            fingerprints: fingerprints
        )

        XCTAssertEqual(reorderedLedger.frames, frames)
        XCTAssertEqual(reorderedLedger.fingerprints, fingerprints)

        var edited = reordered
        edited[1].visualPrompt = "Полностью новый кадр"
        let editedLedger = LiveFruitsFrameLedger.reconciled(
            scenes: edited,
            frames: reorderedLedger.frames,
            fingerprints: reorderedLedger.fingerprints
        )

        XCTAssertNil(editedLedger.frames[original[0].id])
        XCTAssertEqual(editedLedger.frames[original[1].id], "frame-two")
        XCTAssertEqual(editedLedger.frames[original[2].id], "frame-three")
        XCTAssertEqual(editedLedger.frames.count, 2)
    }

    func testPendingStoryRequestReusesOnlyMatchingAccountFingerprint() throws {
        let suite = "fruit-story-pending-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FruitStoryPendingRequestStore(
            defaults: defaults,
            keyPrefix: "tests.fruit-story.pending"
        )
        let accountA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let accountB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let firstFingerprint = FruitStoryQuestionnaireFingerprint.make(.preview)
        var changed = FruitStoryQuestionnaire.preview
        changed.goal = "Новая рекламная цель"
        let changedFingerprint = FruitStoryQuestionnaireFingerprint.make(changed)

        let first = store.requestID(
            userID: accountA,
            fingerprint: firstFingerprint
        )
        XCTAssertEqual(
            store.requestID(userID: accountA, fingerprint: firstFingerprint),
            first
        )
        XCTAssertNotEqual(
            store.requestID(userID: accountA, fingerprint: changedFingerprint),
            first
        )
        XCTAssertNotEqual(
            store.requestID(userID: accountB, fingerprint: firstFingerprint),
            first
        )
    }

    func testPendingStoryRequestClearIsCompareAndClear() throws {
        let suite = "fruit-story-clear-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FruitStoryPendingRequestStore(
            defaults: defaults,
            keyPrefix: "tests.fruit-story.clear"
        )
        let accountID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let fingerprint = FruitStoryQuestionnaireFingerprint.make(.preview)
        let requestID = store.requestID(
            userID: accountID,
            fingerprint: fingerprint
        )

        store.clear(userID: accountID, requestID: UUID())
        XCTAssertEqual(
            store.pending(userID: accountID)?.requestID,
            requestID
        )

        store.clear(userID: accountID, requestID: requestID)
        XCTAssertNil(store.pending(userID: accountID))
    }

    func testPaidImageRequestReusesMatchingAccountSlotAndFingerprint() throws {
        let suite = "fruit-image-pending-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveFruitsImagePendingRequestStore(
            defaults: defaults,
            keyPrefix: "tests.live-fruits.image.pending"
        )
        let accountA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let accountB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        let first = store.requestID(
            userID: accountA,
            slot: "frame.scene-1",
            fingerprint: "fingerprint-a"
        )
        let restartedStore = LiveFruitsImagePendingRequestStore(
            defaults: defaults,
            keyPrefix: "tests.live-fruits.image.pending"
        )

        XCTAssertEqual(
            restartedStore.requestID(
                userID: accountA,
                slot: "frame.scene-1",
                fingerprint: "fingerprint-a"
            ),
            first
        )
        XCTAssertNotEqual(
            store.requestID(
                userID: accountA,
                slot: "frame.scene-2",
                fingerprint: "fingerprint-a"
            ),
            first
        )
        XCTAssertNotEqual(
            store.requestID(
                userID: accountA,
                slot: "frame.scene-1",
                fingerprint: "fingerprint-b"
            ),
            first
        )
        XCTAssertNotEqual(
            store.requestID(
                userID: accountB,
                slot: "frame.scene-1",
                fingerprint: "fingerprint-a"
            ),
            first
        )
    }

    func testPaidImageRequestClearsOnlyMatchingAcceptedInputAndKey() throws {
        let suite = "fruit-image-clear-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveFruitsImagePendingRequestStore(
            defaults: defaults,
            keyPrefix: "tests.live-fruits.image.clear"
        )
        let accountID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let slot = "regenerate.scene-2"
        let fingerprint = "fingerprint-a"
        let requestID = store.requestID(
            userID: accountID,
            slot: slot,
            fingerprint: fingerprint
        )

        store.clear(
            userID: accountID,
            slot: slot,
            fingerprint: "different",
            requestID: requestID
        )
        XCTAssertEqual(
            store.pending(userID: accountID, slot: slot)?.requestID,
            requestID
        )

        store.clear(
            userID: accountID,
            slot: slot,
            fingerprint: fingerprint,
            requestID: UUID().uuidString
        )
        XCTAssertEqual(
            store.pending(userID: accountID, slot: slot)?.requestID,
            requestID
        )

        store.clear(
            userID: accountID,
            slot: slot,
            fingerprint: fingerprint,
            requestID: requestID
        )
        XCTAssertNil(store.pending(userID: accountID, slot: slot))
        XCTAssertNotEqual(
            store.requestID(
                userID: accountID,
                slot: slot,
                fingerprint: fingerprint
            ),
            requestID
        )
    }

    func testPaidImageFingerprintNormalizesTextAndIncludesReferences() {
        let reference = ImageGenerationReference(
            mimeType: "image/png",
            base64: "aW1hZ2U="
        )
        let normalized = LiveFruitsImageRequestFingerprint.make(
            prompt: "  First line\r\nSecond line  ",
            provider: .gptImage2,
            category: ImageGenerationCatalog.custom,
            quantity: 1,
            size: .portrait,
            referenceImages: [reference]
        )
        let equivalent = LiveFruitsImageRequestFingerprint.make(
            prompt: "First line\nSecond line",
            provider: .gptImage2,
            category: ImageGenerationCatalog.custom,
            quantity: 1,
            size: .portrait,
            referenceImages: [reference]
        )
        let changedReference = LiveFruitsImageRequestFingerprint.make(
            prompt: "First line\nSecond line",
            provider: .gptImage2,
            category: ImageGenerationCatalog.custom,
            quantity: 1,
            size: .portrait,
            referenceImages: [
                ImageGenerationReference(
                    mimeType: "image/png",
                    base64: "ZGlmZmVyZW50"
                ),
            ]
        )

        XCTAssertEqual(normalized, equivalent)
        XCTAssertNotEqual(normalized, changedReference)
    }

    private func makeService(
        recorder: FruitStoryRequestRecorder,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> FruitStoryService {
        FruitStoryURLProtocol.handler = { request in
            recorder.lastRequest = request
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FruitStoryURLProtocol.self]
        return FruitStoryService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon-key",
            recoveryDelayNanoseconds: 0,
            maximumRecoveryAttempts: 2
        )
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static let validStoryJSON = """
    {"story":{"title":"Манго открывает кафе","summary":"Короткая история","character_bible":"Один манго с круглыми глазами и синей бабочкой","final_video_prompt":"Vertical cinematic fruit story","scenes":[{"id":"scene-1","title":"Знакомство","visual_prompt":"Манго входит в кафе","action":"Открывает дверь","camera":"Общий план","caption":"Начинаем"},{"id":"scene-2","title":"Напиток","visual_prompt":"Тот же манго готовит лимонад","action":"Смешивает напиток","camera":"Средний план","caption":"Свежий вкус"},{"id":"scene-3","title":"Финал","visual_prompt":"Тот же манго подмигивает","action":"Подмигивает","camera":"Крупный план","caption":"Попробуй сегодня"}]},"request_id":"11111111-1111-4111-8111-111111111111","replayed":false}
    """
}

private final class FruitStoryRequestRecorder: @unchecked Sendable {
    var lastRequest: URLRequest?
}

private final class FruitStoryURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let capturedRequest = try request.materializingHTTPBodyForTesting()
            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
