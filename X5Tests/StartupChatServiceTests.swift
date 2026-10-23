import Foundation
import XCTest
@testable import X5

final class StartupChatServiceTests: XCTestCase {
    override func tearDown() {
        StartupChatURLProtocol.handler = nil
        super.tearDown()
    }

    func testSendUsesAuthenticatedServerOnlyContract() async throws {
        let recorder = StartupChatRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 200),
                Data(
                    """
                    {
                      "reply": "Сначала проверьте спрос на одной аудитории.",
                      "model": "startup-advisor"
                    }
                    """.utf8
                )
            )
        }

        let result = try await service.send(
            messages: [
                StartupChatMessage(role: .user, content: "Хочу открыть кофейню")
            ],
            accessToken: "access-token"
        )

        XCTAssertEqual(
            result.reply,
            "Сначала проверьте спрос на одной аудитории."
        )
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/functions/v1/startup-chat")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "apikey"),
            "anon-key"
        )
        XCTAssertEqual(request.timeoutInterval, 55)

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(
            messages[0]["content"] as? String,
            "Хочу открыть кофейню"
        )
        XCTAssertNotNil(
            UUID(uuidString: try XCTUnwrap(payload["request_id"] as? String))
        )
    }

    func testProviderFailureIsMappedWithoutLeakingProviderDetails() async {
        let service = makeService(
            recorder: StartupChatRequestRecorder()
        ) { request in
            (
                Self.response(for: request, statusCode: 503),
                Data(
                    """
                    {
                      "error": {
                        "code": "assistant_unavailable",
                        "message": "sk-secret internal upstream failure"
                      }
                    }
                    """.utf8
                )
            )
        }

        do {
            _ = try await service.send(
                messages: [
                    StartupChatMessage(role: .user, content: "Помоги с идеей")
                ],
                accessToken: "access-token"
            )
            XCTFail("Expected a server error")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertEqual(
                description,
                "Стартап-помощник временно недоступен. Попробуйте ещё раз."
            )
            XCTAssertFalse(description.contains("sk-secret"))
            XCTAssertFalse(description.contains("upstream"))
        }
    }

    func testTransportNormalizationKeepsNewestHistoryWithinSharedLimits() throws {
        let messages = (0..<13).map { index in
            StartupChatMessage(
                role: index == 12 ? .user : .assistant,
                content: String(repeating: "\(index % 10)", count: 4_000)
            )
        }

        let normalized = try StartupChatService.normalizeForTransport(messages)

        XCTAssertLessThanOrEqual(normalized.count, 12)
        XCTAssertLessThanOrEqual(
            normalized.reduce(0) { $0 + $1.content.utf16.count },
            12_000
        )
        XCTAssertEqual(normalized.last?.role, .user)
        XCTAssertEqual(normalized.last?.content, messages.last?.content)
        XCTAssertEqual(normalized.map(\.id), Array(messages.suffix(3)).map(\.id))
    }

    func testUserMessageNormalizationDoesNotSplitUTF16SurrogatePair() throws {
        let source = String(repeating: "a", count: 3_999) + "🙂tail"

        let normalized = try StartupChatService.normalizeUserMessage(source)

        XCTAssertEqual(normalized, String(repeating: "a", count: 3_999))
        XCTAssertLessThanOrEqual(normalized.utf16.count, 4_000)
        XCTAssertFalse(normalized.contains("\u{FFFD}"))
    }

    func testAssistantReplyUsesTheSameUTF16LimitAsTheNextPayload() throws {
        let source = String(repeating: "a", count: 3_999) + "🙂tail"

        let displayed = try StartupChatService.normalizeAssistantReply(source)
        let nextPayload = try StartupChatService.normalizeForTransport([
            StartupChatMessage(role: .assistant, content: displayed),
            StartupChatMessage(role: .user, content: "next")
        ])

        XCTAssertEqual(displayed, String(repeating: "a", count: 3_999))
        XCTAssertEqual(nextPayload.first?.content, displayed)
        XCTAssertLessThanOrEqual(displayed.utf16.count, 4_000)
        XCTAssertFalse(displayed.contains("\u{FFFD}"))
    }

    func testServerCooldownIsBoundedForRetryUI() {
        XCTAssertEqual(
            StartupChatServiceError.rateLimited(retryAfter: 86_400)
                .retryAfterSeconds,
            86_400
        )
        XCTAssertEqual(
            StartupChatServiceError.inProgress(retryAfter: 3)
                .retryAfterSeconds,
            3
        )
        XCTAssertNil(
            StartupChatServiceError.assistantUnavailable.retryAfterSeconds
        )
    }

    func testPendingRequestStoreReusesOnlyMatchingFingerprint() {
        let suite = "StartupChatPendingRequestStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StartupChatPendingRequestStore(defaults: defaults)

        let first = store.requestID(
            userID: "user-1",
            fingerprint: String(repeating: "a", count: 64)
        )
        let replay = StartupChatPendingRequestStore(defaults: defaults)
            .requestID(
                userID: "user-1",
                fingerprint: String(repeating: "a", count: 64)
            )
        let changed = store.requestID(
            userID: "user-1",
            fingerprint: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(replay, first)
        XCTAssertNotEqual(changed, first)
        store.clear(userID: "user-1", requestID: changed)
        XCTAssertNil(store.pending(userID: "user-1"))
    }

    func testPendingRequestStoreDoesNotClearANewerRequest() {
        let suite = "StartupChatPendingRequestStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StartupChatPendingRequestStore(defaults: defaults)

        let staleRequestID = store.requestID(
            userID: "user-1",
            fingerprint: String(repeating: "a", count: 64)
        )
        let currentRequestID = store.requestID(
            userID: "user-1",
            fingerprint: String(repeating: "b", count: 64)
        )

        store.clear(userID: "user-1", requestID: staleRequestID)

        XCTAssertEqual(
            store.pending(userID: "user-1")?.requestID,
            currentRequestID
        )

        store.clear(userID: "user-1", requestID: currentRequestID)

        XCTAssertNil(store.pending(userID: "user-1"))
    }

    func testConversationContractErrorsMapToInvalidConversation() async {
        for code in [
            "conversation_too_long",
            "too_many_messages",
            "message_too_long",
            "invalid_role",
            "message_empty",
            "invalid_message"
        ] {
            let service = makeService(
                recorder: StartupChatRequestRecorder()
            ) { request in
                (
                    Self.response(for: request, statusCode: 400),
                    Data(
                        """
                        {"error":{"code":"\(code)"}}
                        """.utf8
                    )
                )
            }

            do {
                _ = try await service.send(
                    messages: [
                        StartupChatMessage(
                            role: .user,
                            content: "Проверь идею"
                        )
                    ],
                    accessToken: "access-token"
                )
                XCTFail("Expected invalid conversation for \(code)")
            } catch {
                XCTAssertEqual(
                    error as? StartupChatServiceError,
                    .invalidConversation,
                    "Unexpected mapping for \(code)"
                )
            }
        }
    }

    func testModerationRejectionHasAnExplicitSafeMessage() async {
        let service = makeService(
            recorder: StartupChatRequestRecorder()
        ) { request in
            (
                Self.response(for: request, statusCode: 422),
                Data(
                    """
                    {"error":{"code":"content_rejected"}}
                    """.utf8
                )
            )
        }

        do {
            _ = try await service.send(
                messages: [
                    StartupChatMessage(
                        role: .user,
                        content: "Проверь эту идею"
                    )
                ],
                accessToken: "access-token"
            )
            XCTFail("Expected content rejection")
        } catch {
            XCTAssertEqual(
                error as? StartupChatServiceError,
                .contentRejected
            )
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Сообщение не прошло проверку безопасности. Измените текст и попробуйте ещё раз."
            )
        }
    }

    private func makeService(
        recorder: StartupChatRequestRecorder,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> StartupChatService {
        StartupChatURLProtocol.handler = { request in
            recorder.lastRequest = request
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StartupChatURLProtocol.self]
        return StartupChatService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon-key"
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
}

private final class StartupChatRequestRecorder: @unchecked Sendable {
    var lastRequest: URLRequest?
}

private final class StartupChatURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let capturedRequest = try request.materializingHTTPBodyForTesting()
            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
