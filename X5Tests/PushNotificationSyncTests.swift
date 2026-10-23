import Foundation
import XCTest
@testable import X5

@MainActor
final class PushNotificationSyncTests: XCTestCase {
    override func tearDown() {
        PushSyncURLProtocol.handler = nil
        super.tearDown()
    }

    func testRegistrationUsesFreshTokenProviderInsteadOfCapturedSessionToken() async throws {
        let recorder = PushSyncRequestRecorder()
        PushSyncURLProtocol.handler = { request in
            recorder.record(request)
            return Self.response(for: request, statusCode: 204)
        }

        let service = makeService()
        service.currentUserDidChange(
            userId: "user-1",
            accessToken: "captured-stale-token",
            freshAccessTokenProvider: { "refreshed-token" }
        )
        service.updateDeviceToken(Data([0xab, 0xcd]))

        await service.syncToken()

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(
            recorder.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer refreshed-token"
        )
        XCTAssertEqual(recorder.requests.first?.url?.path, "/functions/v1/register-push-token")
    }

    func testFailedCanonicalRegistrationRemainsRetryableWithoutDirectWrites() async throws {
        let recorder = PushSyncRequestRecorder()
        PushSyncURLProtocol.handler = { request in
            recorder.record(request)
            guard request.url?.path == "/functions/v1/register-push-token" else {
                XCTFail("Unexpected push sync request: \(request)")
                return Self.response(for: request, statusCode: 404)
            }
            return Self.response(for: request, statusCode: 503)
        }

        let service = makeService()
        service.currentUserDidChange(
            userId: "user-1",
            accessToken: "session-token",
            freshAccessTokenProvider: { "session-token" }
        )
        service.updateDeviceToken(Data([0x01, 0x02]))

        await service.syncToken()
        await service.syncToken()

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.url?.path == "/functions/v1/register-push-token"
                && $0.httpMethod == "POST"
        })
    }

    func testLogoutUnregistersExactDeviceTupleBeforeClearingLocalState() async throws {
        let recorder = PushSyncRequestRecorder()
        PushSyncURLProtocol.handler = { request in
            recorder.record(request)
            return Self.response(for: request, statusCode: 204)
        }
        let service = makeService()
        service.currentUserDidChange(
            userId: "user-1",
            accessToken: "session-token",
            freshAccessTokenProvider: { "session-token" }
        )
        service.updateDeviceToken(Data(repeating: 0xab, count: 32))

        let result = await service.unregisterCurrentDevice(
            userId: "user-1",
            accessToken: "session-token"
        )

        XCTAssertTrue(result)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/functions/v1/register-push-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(json["platform"], "ios")
        XCTAssertEqual(json["token"], String(repeating: "ab", count: 32))

        await service.syncToken()
        XCTAssertEqual(recorder.requests.count, 1, "Local token must be cleared after logout")
    }

    func testFailedCanonicalLogoutNeverAttemptsDirectWrites() async throws {
        let recorder = PushSyncRequestRecorder()
        PushSyncURLProtocol.handler = { request in
            recorder.record(request)
            guard request.url?.path == "/functions/v1/register-push-token" else {
                XCTFail("Unexpected push logout request: \(request)")
                return Self.response(for: request, statusCode: 404)
            }
            return Self.response(for: request, statusCode: 503)
        }
        let service = makeService()
        service.currentUserDidChange(
            userId: "user-1",
            accessToken: "session-token",
            freshAccessTokenProvider: { "session-token" }
        )
        service.updateDeviceToken(Data(repeating: 0xcd, count: 32))

        let result = await service.unregisterCurrentDevice(
            userId: "user-1",
            accessToken: "session-token"
        )

        XCTAssertFalse(result)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(
            recorder.requests.first?.url?.path,
            "/functions/v1/register-push-token"
        )
    }

    private func makeService() -> PushNotifications {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushSyncURLProtocol.self]
        return PushNotifications(
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "test-anon-key",
            urlSession: URLSession(configuration: configuration)
        )
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data())
    }
}

private final class PushSyncRequestRecorder {
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

private final class PushSyncURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            // URLSession may move Data bodies into an InputStream before a
            // custom URLProtocol sees the request. Materialize it so the
            // recorder can assert the exact unregister tuple.
            let materializedRequest = try request.materializingHTTPBodyForTesting()
            let (response, data) = try handler(materializedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
