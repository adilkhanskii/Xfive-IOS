import Foundation
import XCTest
@testable import X5

final class ChatMediaPolicyTests: XCTestCase {
    private let host = "afwznqjpshybmqhlewmy.supabase.co"
    private let chatID = "11111111-1111-4111-8111-111111111111"
    private let userID = "22222222-2222-4222-8222-222222222222"

    override func tearDown() {
        ChatMediaURLProtocol.handler = nil
        super.tearDown()
    }

    func testMediaLimitsRejectOversizedAndUnknownPayloads() {
        XCTAssertTrue(ChatMediaPolicy.accepts(byteCount: 1_024, mime: "image/jpeg"))
        XCTAssertFalse(ChatMediaPolicy.accepts(
            byteCount: ChatMediaPolicy.maximumImageBytes + 1,
            mime: "image/jpeg"
        ))
        XCTAssertFalse(ChatMediaPolicy.accepts(byteCount: 1_024, mime: "application/pdf"))
        XCTAssertTrue(ChatMediaPolicy.accepts(
            byteCount: ChatMediaPolicy.maximumVideoBytes,
            mime: "video/mp4"
        ))
        XCTAssertFalse(ChatMediaPolicy.accepts(
            byteCount: ChatMediaPolicy.maximumVideoBytes + 1,
            mime: "video/mp4"
        ))
        XCTAssertTrue(ChatMediaPolicy.accepts(byteCount: 1_024, mime: "video/quicktime"))
    }

    func testStoragePathComponentsCannotEscapeChatFolder() {
        XCTAssertEqual(ChatMediaPolicy.safePathComponent("user-a_user-b"), "user-a_user-b")
        XCTAssertNil(ChatMediaPolicy.safePathComponent("../other"))
        XCTAssertNil(ChatMediaPolicy.safePathComponent("chat/other"))
    }

    func testUploadPathMatchesPrivateBucketRLSLayout() {
        XCTAssertEqual(
            ChatMediaPolicy.uploadObjectPath(
                chatID: chatID,
                userID: userID,
                fileExtension: "JPG",
                timestamp: 1_722_000_000,
                nonce: "ABCDEF1234567890"
            ),
            "\(chatID)/\(userID)/1722000000-ABCDEF123456.jpg"
        )
    }

    func testCanonicalMediaURLExtractsOnlyExactBucketObjectPath() {
        let objectPath = "\(chatID)/\(userID)/1722000000-photo.jpg"
        let publicURL = "https://\(host)/storage/v1/object/public/chat-media/\(objectPath)"
        let authenticatedURL = "https://\(host)/storage/v1/object/authenticated/chat-media/\(objectPath)"

        XCTAssertEqual(
            ChatMediaPolicy.objectPath(
                fromCanonicalURL: publicURL,
                expectedHost: host,
                expectedChatID: chatID
            ),
            objectPath
        )
        XCTAssertEqual(
            ChatMediaPolicy.objectPath(
                fromCanonicalURL: authenticatedURL,
                expectedHost: host,
                expectedChatID: chatID
            ),
            objectPath
        )
    }

    func testLegacyAndroidMediaURLKeepsOriginalObjectPathForSigning() {
        let legacyObjectPath = "chats/\(chatID)/\(userID)/old-photo.jpg"
        let legacyURL = "https://\(host)/storage/v1/object/public/chat-media/\(legacyObjectPath)"

        XCTAssertEqual(
            ChatMediaPolicy.objectPath(
                fromCanonicalURL: legacyURL,
                expectedHost: host,
                expectedChatID: chatID
            ),
            legacyObjectPath
        )
        XCTAssertNil(
            ChatMediaPolicy.objectPath(
                fromCanonicalURL: "https://\(host)/storage/v1/object/public/chat-media/chats/other-chat/photo.jpg",
                expectedHost: host,
                expectedChatID: chatID
            )
        )
        XCTAssertNil(
            ChatMediaPolicy.objectPath(
                fromCanonicalURL: "https://\(host)/storage/v1/object/public/chat-media/chats/\(chatID)/%2E%2E/photo.jpg",
                expectedHost: host,
                expectedChatID: chatID
            )
        )
    }

    func testCanonicalMediaURLRejectsOtherScopeAndTraversal() {
        let goodPath = "\(chatID)/\(userID)/photo.jpg"
        let cases = [
            "http://\(host)/storage/v1/object/public/chat-media/\(goodPath)",
            "https://evil.example/storage/v1/object/public/chat-media/\(goodPath)",
            "https://\(host)/storage/v1/object/public/avatars/\(goodPath)",
            "https://\(host)/storage/v1/object/public/chat-media/other-chat/\(userID)/photo.jpg",
            "https://\(host)/storage/v1/object/public/chat-media/\(chatID)/../photo.jpg",
            "https://\(host)/storage/v1/object/public/chat-media/\(chatID)/%2E%2E/photo.jpg",
            "https://\(host)/storage/v1/object/public/chat-media/\(goodPath)?token=leak",
            "https://\(host)/storage/v1/object/public/chat-media/\(goodPath)#fragment"
        ]

        for value in cases {
            XCTAssertNil(
                ChatMediaPolicy.objectPath(
                    fromCanonicalURL: value,
                    expectedHost: host,
                    expectedChatID: chatID
                ),
                value
            )
        }
    }

    @MainActor
    func testSignedURLUsesJWTExactStorageEndpointAndBoundedCacheKey() async throws {
        ChatsService.clearMemoryCache()
        var requests: [URLRequest] = []
        let objectPath = "\(chatID)/\(userID)/1722000000-photo.jpg"
        ChatMediaURLProtocol.handler = { request in
            requests.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {"signedURL":"/object/sign/chat-media/\(objectPath)?token=signed-token-\(requests.count)"}
            """.data(using: .utf8)!
            return (response, body)
        }
        let service = makeService()
        let canonicalURL = "https://\(host)/storage/v1/object/public/chat-media/\(objectPath)"

        let first = await service.signedMediaURL(
            canonicalURL: canonicalURL,
            chatId: chatID,
            currentUserId: userID,
            accessToken: "user-jwt"
        )
        let cached = await service.signedMediaURL(
            canonicalURL: canonicalURL,
            chatId: chatID,
            currentUserId: userID,
            accessToken: "user-jwt"
        )
        let refreshed = await service.signedMediaURL(
            canonicalURL: canonicalURL,
            chatId: chatID,
            currentUserId: userID,
            accessToken: "user-jwt",
            forceRefresh: true
        )

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(first, cached)
        XCTAssertNotEqual(first, refreshed)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/storage/v1/object/sign/chat-media/\(objectPath)"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Int])
        XCTAssertEqual(json["expiresIn"], 600)
    }

    @MainActor
    func testSignedURLRejectsRedirectToForeignHost() async {
        ChatsService.clearMemoryCache()
        ChatMediaURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"signedURL":"https://evil.example/file?token=stolen"}"#.utf8))
        }
        let service = makeService()
        let objectPath = "\(chatID)/\(userID)/photo.jpg"

        let result = await service.signedMediaURL(
            canonicalURL: "https://\(host)/storage/v1/object/public/chat-media/\(objectPath)",
            chatId: chatID,
            currentUserId: userID,
            accessToken: "user-jwt"
        )

        XCTAssertNil(result)
    }

    @MainActor
    func testChat401RetriesThroughConfiguredSharedTokenProviderOnly() async throws {
        var requests: [URLRequest] = []
        var rejectedTokens: [String] = []
        let objectPath = "\(chatID)/\(userID)/photo.jpg"
        ChatMediaURLProtocol.handler = { request in
            requests.append(request)
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if authorization == "Bearer expired-token" {
                return (Self.httpResponse(for: request, statusCode: 401), Data())
            }
            XCTAssertEqual(authorization, "Bearer shared-refreshed-token")
            let body = """
            {"signedURL":"/object/sign/chat-media/\(objectPath)?token=signed-token"}
            """
            return (Self.httpResponse(for: request, statusCode: 200), Data(body.utf8))
        }
        let service = makeService()
        service.configureAccessTokenProvider { rejectedToken in
            rejectedTokens.append(rejectedToken)
            return "shared-refreshed-token"
        }

        let result = await service.signedMediaURL(
            canonicalURL: "https://\(host)/storage/v1/object/public/chat-media/\(objectPath)",
            chatId: chatID,
            currentUserId: userID,
            accessToken: "expired-token",
            forceRefresh: true
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(rejectedTokens, ["expired-token"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path != "/auth/v1/token" })
    }

    @MainActor
    func testVideoMessageUsesCanonicalPrivateMediaReferenceAndVideoPreview() async throws {
        var requests: [URLRequest] = []
        let objectPath = "\(chatID)/\(userID)/1722000000-clip.mp4"
        let canonicalURL = "https://\(host)/storage/v1/object/public/chat-media/\(objectPath)"
        ChatMediaURLProtocol.handler = { request in
            requests.append(request)
            if request.url?.path == "/rest/v1/messages" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let body = """
                [{
                  "id":"message-1",
                  "chat_id":"\(self.chatID)",
                  "sender_id":"\(self.userID)",
                  "type":"video",
                  "content":null,
                  "media_url":"\(canonicalURL)",
                  "media_mime":"video/mp4",
                  "created_at":"2026-08-01T00:00:00Z"
                }]
                """
                return (response, Data(body.utf8))
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let inserted = await makeService().sendMedia(
            chatId: chatID,
            currentUserId: userID,
            type: "video",
            mediaUrl: canonicalURL,
            mime: "video/mp4",
            accessToken: "user-jwt"
        )

        XCTAssertEqual(inserted?.type, "video")
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/rest/v1/messages",
            "/rest/v1/chats"
        ])
        let insertBody = try XCTUnwrap(requests.first?.httpBody)
        let insertJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: insertBody) as? [String: String]
        )
        XCTAssertEqual(insertJSON["type"], "video")
        XCTAssertEqual(insertJSON["media_url"], canonicalURL)

        let previewBody = try XCTUnwrap(requests.last?.httpBody)
        let previewJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: previewBody) as? [String: String]
        )
        XCTAssertEqual(previewJSON["last_message"], "🎬 Видео")
    }

    @MainActor
    private func makeService() -> ChatsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatMediaURLProtocol.self]
        return ChatsService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://\(host)")!,
            anonKey: "anon-key"
        )
    }

    private static func httpResponse(
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

private final class ChatMediaURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            var capturedRequest = request
            if capturedRequest.httpBody == nil,
               let stream = capturedRequest.httpBodyStream,
               let body = Self.readBody(from: stream) {
                capturedRequest.httpBody = body
            }
            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return body }
            body.append(buffer, count: count)
        }
    }
}
