import Foundation
import XCTest
@testable import X5

/// Жалоба на результат ИИ: строка в public.reports (как у веба) и пуш разработчикам.
final class AIContentReportServiceTests: XCTestCase {
    override func tearDown() {
        AIContentReportURLProtocol.handler = nil
        super.tearDown()
    }

    private let report = AIContentReport(
        tool: "image:custom",
        reason: .sexual,
        comment: "  bad result  ",
        contentURL: "asset:abc",
        contentText: nil,
        prompt: "a cat"
    )

    func testRowMatchesWebFormat() throws {
        let data = try AIContentReportService.rowBody(for: report, userId: "user-1")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(row["reporter_id"] as? String, "user-1")
        XCTAssertEqual(row["reported_user_id"] as? String, "user-1")
        XCTAssertEqual(row["reported_user_name"] as? String, "AI:image:custom")

        let reasonJSON = try XCTUnwrap(row["reason"] as? String)
        let details = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(reasonJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual(details["kind"] as? String, "ai_content")
        XCTAssertEqual(details["tool"] as? String, "image:custom")
        XCTAssertEqual(details["reason"] as? String, "sexual")
        XCTAssertEqual(details["comment"] as? String, "bad result")
        XCTAssertEqual(details["content_url"] as? String, "asset:abc")
        XCTAssertTrue(details["content_text"] is NSNull)
        XCTAssertEqual(details["prompt"] as? String, "a cat")
        XCTAssertEqual(details["page"] as? String, "ios")
    }

    func testLongFieldsAreClipped() throws {
        var long = report
        long.comment = String(repeating: "a", count: 1_500)
        long.prompt = String(repeating: "b", count: 1_500)
        let data = try AIContentReportService.rowBody(for: long, userId: "user-1")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let details = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(row["reason"] as? String).utf8)) as? [String: Any]
        )
        XCTAssertEqual((details["comment"] as? String)?.count, 1_000)
        XCTAssertEqual((details["prompt"] as? String)?.count, 1_000)
    }

    func testReferencePrefersAssetID() {
        let url = URL(string: "https://example.com/signed.mp4")!
        XCTAssertEqual(AIContentReport.reference(assetID: "a1", url: url), "asset:a1")
        XCTAssertEqual(AIContentReport.reference(assetID: nil, url: url), url.absoluteString)
        XCTAssertNil(AIContentReport.reference(assetID: "", url: nil))
    }

    func testSendPostsReportWithUserToken() async throws {
        let recorder = AIContentReportRequestRecorder()
        AIContentReportURLProtocol.handler = { request in
            recorder.record(try request.materializingHTTPBodyForTesting())
            return (Self.response(for: request, status: 201), Data())
        }

        try await makeService().send(report, userId: "user-1", accessToken: "session-token")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/rest/v1/reports")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
        XCTAssertNotNil(request.httpBody)
    }

    func testSendThrowsWhenServerRejects() async {
        AIContentReportURLProtocol.handler = { request in
            (Self.response(for: request, status: 401), Data())
        }

        do {
            try await makeService().send(report, userId: "user-1", accessToken: "expired")
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? AIContentReportServiceError, .http(statusCode: 401))
        }
    }

    func testDevelopersGetOnePushEach() async throws {
        let recorder = AIContentReportRequestRecorder()
        AIContentReportURLProtocol.handler = { request in
            recorder.record(try request.materializingHTTPBodyForTesting())
            return (Self.response(for: request, status: 200), Data())
        }

        await makeService().notifyDevelopers(report)

        XCTAssertEqual(recorder.requests.count, Roles.developerUserIds.count)
        var recipients = Set<String>()
        for request in recorder.requests {
            XCTAssertEqual(request.url?.host, "push.example.com")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
            )
            XCTAssertEqual(body["title"] as? String, AIContentReportService.pushTitle)
            XCTAssertEqual(body["body"] as? String, "image:custom: sexual — bad result")
            recipients.insert(try XCTUnwrap(body["to_user_id"] as? String))
        }
        XCTAssertEqual(recipients, Roles.developerUserIds)
    }

    private func makeService() -> AIContentReportService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIContentReportURLProtocol.self]
        return AIContentReportService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "test-anon-key",
            pushURL: URL(string: "https://push.example.com/send-push")!
        )
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private final class AIContentReportURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AIContentReportRequestRecorder {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}
