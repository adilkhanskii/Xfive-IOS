import Foundation
import XCTest
@testable import X5

private let pinTestHost = "afwznqjpshybmqhlewmy.supabase.co"
private let pinTestChatID = "user-a_user-b"
private let pinTestMessageID = "33333333-3333-4333-8333-333333333333"

/// Закреп сообщения в чате (chats.pinned_message_id) — общий для обоих участников.
/// Баг Адильхана 09.10: закреп жил только в памяти телефона, плашки не было.
@MainActor
final class ChatPinTests: XCTestCase {
    override func tearDown() {
        ChatPinURLProtocol.handler = nil
        super.tearDown()
    }

    func testPinSendsPatchWithMessageIdAndConfirmsByEcho() async throws {
        var captured: URLRequest?
        ChatPinURLProtocol.handler = { request in
            captured = request
            let body = #"[{"pinned_message_id":"\#(pinTestMessageID)"}]"#
            return (Self.response(request, 200), Data(body.utf8))
        }

        let ok = await makeService().setPinnedMessage(chatId: pinTestChatID, messageId: pinTestMessageID, accessToken: "token")

        XCTAssertTrue(ok)
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/rest/v1/chats")
        XCTAssertEqual(request.url?.query, "id=eq.\(pinTestChatID)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["pinned_message_id"] as? String, pinTestMessageID)
    }

    func testUnpinSendsJSONNull() async throws {
        var captured: URLRequest?
        ChatPinURLProtocol.handler = { request in
            captured = request
            return (Self.response(request, 200), Data(#"[{"pinned_message_id":null}]"#.utf8))
        }

        let ok = await makeService().setPinnedMessage(chatId: pinTestChatID, messageId: nil, accessToken: "token")

        XCTAssertTrue(ok)
        let body = try XCTUnwrap(captured?.httpBody)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"pinned_message_id":null}"#)
    }

    func testPinFailsWhenServerUpdatedNoRows() async {
        // RLS не пустил — PostgREST отвечает 200 и пустым массивом. Это НЕ успех.
        ChatPinURLProtocol.handler = { request in
            (Self.response(request, 200), Data("[]".utf8))
        }

        let ok = await makeService().setPinnedMessage(chatId: pinTestChatID, messageId: nil, accessToken: "token")

        XCTAssertFalse(ok)
    }

    func testLoadPinnedDistinguishesNoPinFromUnknown() async {
        ChatPinURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.query, "id=eq.\(pinTestChatID)&select=pinned_message_id")
            return (Self.response(request, 200), Data(#"[{"pinned_message_id":null}]"#.utf8))
        }
        let none = await makeService().loadPinnedMessage(chatId: pinTestChatID, accessToken: "token")
        XCTAssertEqual(none, ChatPinState(messageId: nil))

        // База без миграции: колонки нет → 400. Экран не должен считать, что закреп сняли.
        ChatPinURLProtocol.handler = { request in
            (Self.response(request, 400), Data(#"{"code":"42703"}"#.utf8))
        }
        let unknown = await makeService().loadPinnedMessage(chatId: pinTestChatID, accessToken: "token")
        XCTAssertNil(unknown)
    }

    func testLoadSingleMessageIsScopedToChat() async throws {
        var captured: URLRequest?
        ChatPinURLProtocol.handler = { request in
            captured = request
            let body = #"[{"id":"\#(pinTestMessageID)","chat_id":"\#(pinTestChatID)","sender_id":"user-a","type":"audio","content":"0:04"}]"#
            return (Self.response(request, 200), Data(body.utf8))
        }

        let row = await makeService().loadMessage(id: pinTestMessageID, chatId: pinTestChatID, accessToken: "token")

        XCTAssertEqual(row?.id, pinTestMessageID)
        let query = try XCTUnwrap(captured?.url?.query)
        XCTAssertTrue(query.contains("chat_id=eq.\(pinTestChatID)"))
        XCTAssertTrue(query.contains("id=eq.\(pinTestMessageID)"))
    }

    private func makeService() -> ChatsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatPinURLProtocol.self]
        return ChatsService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://\(pinTestHost)")!,
            anonKey: "anon-key"
        )
    }

    nonisolated private static func response(_ request: URLRequest, _ statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private final class ChatPinURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let materialized = try request.materializingHTTPBodyForTesting()
            let (response, data) = try handler(materialized)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
