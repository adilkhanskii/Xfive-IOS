import Foundation
import XCTest
@testable import X5

@MainActor
final class CoursePurchaseServiceRetryTests: XCTestCase {
    override func tearDown() {
        CoursePurchaseURLProtocol.reset()
        super.tearDown()
    }

    func testUnauthorizedResponseRefreshesTokenAndRetriesExactlyOnce() async throws {
        let recorder = LockedRequestRecorder()
        CoursePurchaseURLProtocol.handler = { request in
            let attempt = recorder.record(request)
            if attempt == 1 {
                return Self.response(for: request, statusCode: 401, body: #"{"message":"JWT expired"}"#)
            }
            return Self.response(
                for: request,
                statusCode: 200,
                body: #"{"status":"purchased","course_id":"11111111-1111-4111-8111-111111111111","credits_remaining":50000,"course_price":50000,"charged_amount":50000}"#
            )
        }

        let service = makeService()
        var refreshCount = 0
        let result = try await service.purchase(
            courseId: "11111111-1111-4111-8111-111111111111",
            expectedPrice: 50_000,
            accessToken: "expired-token",
            refreshAccessToken: {
                refreshCount += 1
                return "fresh-token"
            }
        )

        XCTAssertEqual(result.status, .purchased)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(recorder.authorizationHeaders, ["Bearer expired-token", "Bearer fresh-token"])
    }

    func testSecondUnauthorizedResponseStopsWithoutAnotherRefresh() async throws {
        let recorder = LockedRequestRecorder()
        CoursePurchaseURLProtocol.handler = { request in
            _ = recorder.record(request)
            return Self.response(for: request, statusCode: 401, body: #"{"message":"JWT expired"}"#)
        }

        let service = makeService()
        var refreshCount = 0

        do {
            _ = try await service.purchase(
                courseId: "11111111-1111-4111-8111-111111111111",
                expectedPrice: 50_000,
                accessToken: "expired-token",
                refreshAccessToken: {
                    refreshCount += 1
                    return "still-expired-token"
                }
            )
            XCTFail("Expected the second unauthorized response to fail")
        } catch let error as CoursePurchaseServiceError {
            XCTAssertEqual(error, .http(statusCode: 401, message: "JWT expired"))
        }

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(recorder.authorizationHeaders.count, 2)
    }

    func testServerFailureIsNotRetriedBecausePostOutcomeCouldBeUnknown() async throws {
        let recorder = LockedRequestRecorder()
        CoursePurchaseURLProtocol.handler = { request in
            _ = recorder.record(request)
            return Self.response(for: request, statusCode: 500, body: #"{"message":"server failed"}"#)
        }

        let service = makeService()
        var refreshCount = 0

        do {
            _ = try await service.purchase(
                courseId: "11111111-1111-4111-8111-111111111111",
                expectedPrice: 50_000,
                accessToken: "valid-token",
                refreshAccessToken: {
                    refreshCount += 1
                    return "unused-token"
                }
            )
            XCTFail("Expected the server failure to be returned")
        } catch let error as CoursePurchaseServiceError {
            XCTAssertEqual(error, .http(statusCode: 500, message: "server failed"))
        }

        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(recorder.authorizationHeaders, ["Bearer valid-token"])
    }

    private func makeService() -> CoursePurchaseService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoursePurchaseURLProtocol.self]
        return CoursePurchaseService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "test-anon-key"
        )
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class LockedRequestRecorder {
    private let lock = NSLock()
    private var headers: [String] = []

    var authorizationHeaders: [String] {
        lock.lock()
        defer { lock.unlock() }
        return headers
    }

    @discardableResult
    func record(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        return headers.count
    }
}

private final class CoursePurchaseURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

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
