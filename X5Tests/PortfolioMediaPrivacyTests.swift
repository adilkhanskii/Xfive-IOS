import Foundation
import XCTest
@testable import X5

@MainActor
final class PortfolioMediaPrivacyTests: XCTestCase {
    override func tearDown() {
        PortfolioMediaURLProtocol.handler = nil
        super.tearDown()
    }

    func testCanonicalPortfolioPolicyAcceptsOnlyExactSafeObjectIdentifiers() {
        let host = "example.supabase.co"
        XCTAssertEqual(
            PortfolioMediaPolicy.objectPath(
                fromCanonicalURL: "https://\(host)/storage/v1/object/public/portfolio/user-1/work.jpg",
                expectedHost: host
            ),
            "user-1/work.jpg"
        )
        XCTAssertEqual(
            PortfolioMediaPolicy.objectPath(
                fromCanonicalURL: "https://\(host)/storage/v1/object/portfolio/user-1/thumbnails/work.jpg",
                expectedHost: host
            ),
            "user-1/thumbnails/work.jpg"
        )
        XCTAssertNil(PortfolioMediaPolicy.objectPath(
            fromCanonicalURL: "https://evil.example/storage/v1/object/public/portfolio/user-1/work.jpg",
            expectedHost: host
        ))
        XCTAssertNil(PortfolioMediaPolicy.objectPath(
            fromCanonicalURL: "https://\(host)/storage/v1/object/public/portfolio/user-1/%2e%2e/secret.jpg",
            expectedHost: host
        ))
        XCTAssertNil(PortfolioMediaPolicy.objectPath(
            fromCanonicalURL: "https://\(host)/storage/v1/object/public/portfolio/user-1/work.jpg?token=borrowed",
            expectedHost: host
        ))
    }

    func testLoadKeepsCanonicalIdentifierAndRendersOnlySignedURL() async throws {
        let recorder = PortfolioMediaRequestRecorder()
        let canonical = "https://example.supabase.co/storage/v1/object/public/portfolio/user-1/work.jpg"
        PortfolioMediaURLProtocol.handler = { request in
            recorder.record(request)
            if request.url?.path == "/rest/v1/portfolio_items" {
                let body = """
                [{
                  "id":"item-1",
                  "user_id":"user-1",
                  "type":"image",
                  "media_url":"\(canonical)",
                  "thumbnail_url":"\(canonical)",
                  "moderation_status":"approved"
                }]
                """
                return Self.response(for: request, data: Data(body.utf8))
            }
            if request.url?.path == "/rest/v1/profiles" {
                let body = """
                [{"id":"user-1","name":"Portfolio owner","avatar":null,"nickname":"owner"}]
                """
                return Self.response(for: request, data: Data(body.utf8))
            }
            XCTAssertEqual(
                request.url?.path,
                "/storage/v1/object/sign/portfolio/user-1/work.jpg"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token")
            let requestBody = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Int]
            )
            XCTAssertEqual(json["expiresIn"], 600)
            return Self.response(
                for: request,
                data: Data(#"{"signedURL":"/object/sign/portfolio/user-1/work.jpg?token=signed-token"}"#.utf8)
            )
        }

        let service = makeService()
        await service.load(userId: "user-1", accessToken: "fresh-token")

        let item = try XCTUnwrap(service.items.first)
        XCTAssertEqual(item.mediaUrl, canonical, "Never persist an expiring URL as the object identifier")
        XCTAssertEqual(
            item.displayMediaUrl,
            "https://example.supabase.co/storage/v1/object/sign/portfolio/user-1/work.jpg?token=signed-token"
        )
        XCTAssertEqual(item.displayThumbnailUrl, item.displayMediaUrl)
        XCTAssertEqual(
            recorder.requests.filter { $0.url?.path.contains("/object/sign/portfolio/") == true }.count,
            1,
            "Identical media and thumbnail identifiers must share the bounded cache"
        )
    }

    func testSigningRejectsForeignHostReturnedByStorage() async {
        PortfolioMediaURLProtocol.handler = { request in
            Self.response(
                for: request,
                data: Data(#"{"signedURL":"https://evil.example/work.jpg?token=stolen"}"#.utf8)
            )
        }
        let service = makeService()
        let result = await service.signedPortfolioMediaURL(
            canonicalURL: "https://example.supabase.co/storage/v1/object/public/portfolio/user-1/work.jpg",
            accessToken: "fresh-token"
        )
        XCTAssertNil(result)
    }

    private func makeService() -> PortfolioService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortfolioMediaURLProtocol.self]
        return PortfolioService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "test-anon-key",
            functionsBaseURL: URL(string: "https://example.functions.supabase.co")!
        )
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }
}

private final class PortfolioMediaRequestRecorder {
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

private final class PortfolioMediaURLProtocol: URLProtocol {
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
