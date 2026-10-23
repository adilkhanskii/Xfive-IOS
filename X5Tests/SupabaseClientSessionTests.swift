import Foundation
import XCTest
@testable import X5

@MainActor
final class SupabaseClientSessionTests: XCTestCase {
    func testStaleRefreshCannotOverwriteAChangedAccountSession() async throws {
        let requestStarted = expectation(description: "refresh request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupabaseSessionURLProtocol.self]
        SupabaseSessionURLProtocol.handler = { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 3)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "access_token": "stale-access",
              "refresh_token": "stale-refresh-next",
              "user": {
                "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "email": "old@example.com"
              }
            }
            """
            return (response, Data(body.utf8))
        }

        let client = SupabaseClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon-key"
        )
        client.accessToken = "old-access"
        client.refreshToken = "old-refresh"

        let refresh = Task { @MainActor in
            try await client.refreshSession()
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        client.accessToken = "new-access"
        client.refreshToken = "new-refresh"
        releaseResponse.signal()

        do {
            _ = try await refresh.value
            XCTFail("Expected stale refresh to be rejected")
        } catch SupabaseError.staleSession {
            XCTAssertFalse(SupabaseError.staleSession.invalidatesSession)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(client.accessToken, "new-access")
        XCTAssertEqual(client.refreshToken, "new-refresh")
    }

    func testExplicitImageTokenIsUsedWithoutReadingSharedSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupabaseSessionURLProtocol.self]
        SupabaseSessionURLProtocol.handler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer captured-account-token"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
              "imageBase64": "aW1hZ2U=",
              "prompt": "fruit",
              "creditsRemaining": 900
            }
            """
            return (response, Data(body.utf8))
        }

        let client = SupabaseClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon-key"
        )
        client.accessToken = "different-shared-token"
        client.refreshToken = "different-shared-refresh"

        _ = try await client.generateImageWithAccessToken(
            prompt: "fruit",
            provider: .gptImage2,
            category: ImageGenerationCatalog.custom,
            quantity: 1,
            size: .portrait,
            referenceImages: [],
            idempotencyKey: "33333333-3333-4333-8333-333333333333",
            accessToken: "captured-account-token"
        )
    }
}

private final class SupabaseSessionURLProtocol: URLProtocol {
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
            let (response, data) = try handler(request)
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
