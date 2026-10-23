import Foundation
import XCTest
@testable import X5

final class VoiceGenerationServiceTests: XCTestCase {
    override func tearDown() {
        VoiceGenerationURLProtocol.handler = nil
        super.tearDown()
    }

    func testGenerateUsesAuthenticatedIdempotentEdgeContract() async throws {
        let recorder = VoiceGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 200),
                Data(
                    """
                    {
                      "audio_url": "https://project.supabase.co/storage/v1/object/sign/audio",
                      "audio_url_expires_at": "2026-07-26T12:15:00.000Z",
                      "credits_remaining": 940,
                      "cost_credits": 60,
                      "voice": "Aria",
                      "model": "eleven-v3",
                      "replayed": false
                    }
                    """.utf8
                )
            )
        }

        let result = try await service.generate(
            text: "  Озвучь этот рекламный текст  ",
            voice: .aria,
            stability: .balanced,
            speed: 1,
            languageCode: "ru",
            requestID: "22222222-2222-4222-8222-222222222222",
            accessToken: "access-token"
        )

        XCTAssertEqual(result.creditsRemaining, 940)
        XCTAssertEqual(result.costCredits, 60)
        XCTAssertEqual(result.voice, "Aria")
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/functions/v1/generate-voice")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "22222222-2222-4222-8222-222222222222"
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(payload["text"] as? String, "Озвучь этот рекламный текст")
        XCTAssertEqual(payload["voice"] as? String, "Russian_BrightHeroine")
        XCTAssertEqual(payload["stability"] as? Double, 0.5)
        XCTAssertEqual(payload["speed"] as? Double, 1)
        XCTAssertEqual(payload["language_code"] as? String, "ru")
        XCTAssertEqual(
            payload["request_id"] as? String,
            "22222222-2222-4222-8222-222222222222"
        )
    }

    func testCostMatchesServerBlocks() {
        XCTAssertEqual(VoiceGenerationService.creditCost(for: "a"), 60)
        XCTAssertEqual(
            VoiceGenerationService.creditCost(for: String(repeating: "a", count: 1_000)),
            60
        )
        XCTAssertEqual(
            VoiceGenerationService.creditCost(for: String(repeating: "a", count: 1_001)),
            120
        )
    }

    func testRejectsInvalidInputBeforeNetwork() async {
        let recorder = VoiceGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { _ in
            XCTFail("Invalid input must not reach the network")
            throw URLError(.badServerResponse)
        }

        do {
            _ = try await service.generate(
                text: String(repeating: "a", count: 5_001),
                voice: .aria,
                stability: .balanced,
                speed: 1,
                languageCode: nil,
                requestID: "22222222-2222-4222-8222-222222222222",
                accessToken: "access-token"
            )
            XCTFail("Expected invalidText")
        } catch {
            XCTAssertEqual(error as? VoiceGenerationServiceError, .invalidText)
        }
        XCTAssertNil(recorder.lastRequest)
    }

    func testPendingRequestIDPersistsPerUserAndInputUntilSuccess() throws {
        let suiteName = "VoiceGenerationServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VoiceGenerationLocalStore(defaults: defaults)
        let userID = "11111111-1111-4111-8111-111111111111"

        let first = store.pendingRequestID(
            for: "a".repeatToSHA256Length,
            userID: userID
        )
        XCTAssertEqual(
            store.pendingRequestID(
                for: "a".repeatToSHA256Length,
                userID: userID
            ),
            first
        )

        let changed = store.pendingRequestID(
            for: "b".repeatToSHA256Length,
            userID: userID
        )
        XCTAssertNotEqual(changed, first)
        store.clearPending(
            acceptedRequestID: first,
            fingerprint: "a".repeatToSHA256Length,
            userID: userID
        )
        XCTAssertEqual(
            store.pendingRequestID(
                for: "b".repeatToSHA256Length,
                userID: userID
            ),
            changed
        )

        store.clearPending(
            acceptedRequestID: changed,
            fingerprint: "b".repeatToSHA256Length,
            userID: userID
        )
        XCTAssertNotEqual(
            store.pendingRequestID(
                for: "b".repeatToSHA256Length,
                userID: userID
            ),
            changed
        )
    }

    func testPendingRequestIDsSurviveSwitchingBetweenInputs() throws {
        let suiteName = "VoiceGenerationServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VoiceGenerationLocalStore(defaults: defaults)
        let userID = "11111111-1111-4111-8111-111111111111"
        let fingerprintA = "a".repeatToSHA256Length
        let fingerprintB = "b".repeatToSHA256Length

        let requestA = store.pendingRequestID(
            for: fingerprintA,
            userID: userID
        )
        let requestB = store.pendingRequestID(
            for: fingerprintB,
            userID: userID
        )

        XCTAssertNotEqual(requestA, requestB)
        XCTAssertEqual(
            store.pendingRequestID(for: fingerprintA, userID: userID),
            requestA
        )
        XCTAssertEqual(
            store.pendingRequestID(for: fingerprintB, userID: userID),
            requestB
        )
    }

    func testProviderFailureDoesNotLeakServerDetails() async {
        let service = makeService(
            recorder: VoiceGenerationRequestRecorder()
        ) { request in
            (
                Self.response(for: request, statusCode: 503),
                Data(
                    """
                    {
                      "error": {
                        "code": "voice_unavailable",
                        "message": "FAL_KEY secret upstream trace"
                      },
                      "refunded": true
                    }
                    """.utf8
                )
            )
        }

        do {
            _ = try await service.generate(
                text: "Озвучь этот текст",
                voice: .aria,
                stability: .balanced,
                speed: 1,
                languageCode: "ru",
                requestID: "22222222-2222-4222-8222-222222222222",
                accessToken: "access-token"
            )
            XCTFail("Expected server error")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertEqual(
                description,
                "Сервис озвучки временно недоступен. Кредиты возвращены — попробуйте ещё раз."
            )
            XCTAssertFalse(description.contains("FAL_KEY"))
            XCTAssertFalse(description.contains("upstream"))
        }
    }

    func testPendingQueueResponsePollsSameRequestUntilAudioIsReady() async throws {
        let recorder = VoiceGenerationRequestRecorder()
        let service = makeService(
            recorder: recorder,
            sleeper: { _ in }
        ) { request in
            if recorder.requestCount < 3 {
                return (
                    Self.response(
                        for: request,
                        statusCode: 425,
                        headers: [
                            "Content-Type": "application/json",
                            "Retry-After": "1",
                        ]
                    ),
                    Data(
                        """
                        {
                          "error": {
                            "code": "generation_status_pending",
                            "message": "still processing"
                          }
                        }
                        """.utf8
                    )
                )
            }
            return (
                Self.response(for: request, statusCode: 200),
                Data(
                    """
                    {
                      "audio_url": "https://project.supabase.co/storage/v1/object/sign/audio",
                      "audio_url_expires_at": "2026-07-26T12:15:00.000Z",
                      "credits_remaining": 940,
                      "cost_credits": 60,
                      "voice": "Aria",
                      "model": "eleven-v3",
                      "replayed": false
                    }
                    """.utf8
                )
            )
        }

        let result = try await service.generate(
            text: "Озвучь это",
            voice: .aria,
            stability: .balanced,
            speed: 1,
            languageCode: "ru",
            requestID: "22222222-2222-4222-8222-222222222222",
            accessToken: "access-token"
        )

        XCTAssertEqual(result.creditsRemaining, 940)
        XCTAssertEqual(recorder.requestCount, 3)
        XCTAssertEqual(
            Set(recorder.requests.compactMap {
                $0.value(forHTTPHeaderField: "Idempotency-Key")
            }),
            Set(["22222222-2222-4222-8222-222222222222"])
        )
    }

    func testUnauthorizedRequestRefreshesTokenAndRetriesSameOperation() async throws {
        let recorder = VoiceGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            if recorder.requestCount == 1 {
                return (
                    Self.response(for: request, statusCode: 401),
                    Data(
                        """
                        {"error":{"code":"unauthorized"}}
                        """.utf8
                    )
                )
            }
            return (
                Self.response(for: request, statusCode: 200),
                Data(
                    """
                    {
                      "audio_url": "https://project.supabase.co/storage/v1/object/sign/audio",
                      "audio_url_expires_at": "2026-07-26T12:15:00.000Z",
                      "credits_remaining": 940,
                      "cost_credits": 60,
                      "voice": "Aria",
                      "model": "speech-2.8-turbo",
                      "replayed": false
                    }
                    """.utf8
                )
            )
        }

        let result = try await service.generateWithTokenRefresh(
            text: "Озвучь это",
            voice: .aria,
            stability: .balanced,
            speed: 1,
            languageCode: "ru",
            requestID: "22222222-2222-4222-8222-222222222222",
            accessToken: "expired-token",
            refreshAccessToken: { rejectedToken in
                XCTAssertEqual(rejectedToken, "expired-token")
                return "fresh-token"
            }
        )

        XCTAssertEqual(result.model, "speech-2.8-turbo")
        XCTAssertEqual(recorder.requestCount, 2)
        XCTAssertEqual(
            recorder.requests.map {
                $0.value(forHTTPHeaderField: "Authorization")
            },
            ["Bearer expired-token", "Bearer fresh-token"]
        )
        XCTAssertEqual(
            Set(recorder.requests.compactMap {
                $0.value(forHTTPHeaderField: "Idempotency-Key")
            }),
            Set(["22222222-2222-4222-8222-222222222222"])
        )
    }

    func testSharePreparationDownloadsARealLocalMP3() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceGenerationURLProtocol.self]
        let mp3 = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00])
        VoiceGenerationURLProtocol.handler = { request in
            (
                Self.response(
                    for: request,
                    statusCode: 200,
                    headers: ["Content-Type": "audio/mpeg"]
                ),
                mp3
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = VoiceGenerationShareFileService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://project.supabase.co")!,
            directory: root
        )

        let fileURL = try await service.prepare(
            audioURL: URL(
                string: "https://project.supabase.co/storage/v1/object/sign/audio"
            )!,
            requestID: "22222222-2222-4222-8222-222222222222"
        )

        XCTAssertTrue(fileURL.isFileURL)
        XCTAssertEqual(fileURL.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: fileURL), mp3)
        service.remove(fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeService(
        recorder: VoiceGenerationRequestRecorder,
        sleeper: @escaping (UInt64) async throws -> Void = { _ in },
        response: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> VoiceGenerationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceGenerationURLProtocol.self]
        VoiceGenerationURLProtocol.handler = { request in
            recorder.record(request)
            return try response(request)
        }
        return VoiceGenerationService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://project.supabase.co")!,
            anonKey: "anon-key",
            sleeper: sleeper
        )
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String] = [
            "Content-Type": "application/json"
        ]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}

private extension String {
    var repeatToSHA256Length: String {
        String(repeating: self, count: 64)
    }
}

private final class VoiceGenerationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.last
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
    }
}

private final class VoiceGenerationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
