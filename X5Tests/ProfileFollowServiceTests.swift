import Foundation
import XCTest
@testable import X5

final class ProfileFollowServiceTests: XCTestCase {
    override func tearDown() {
        ProfileFollowURLProtocol.handler = nil
        super.tearDown()
    }

    func testCountsUseTheSameColumnMappingForOwnAndPublicProfiles() async throws {
        let recorder = ProfileFollowRequestRecorder()
        ProfileFollowURLProtocol.handler = { request in
            recorder.record(request)
            let items = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []

            if items.contains(where: {
                $0.name == "following_id" && $0.value == "eq.profile-id"
            }) {
                return Self.response(
                    for: request,
                    contentRange: "0-0/2"
                )
            }
            if items.contains(where: {
                $0.name == "follower_id" && $0.value == "eq.profile-id"
            }) {
                return Self.response(
                    for: request,
                    contentRange: "0-0/3"
                )
            }
            XCTFail("Unexpected follow-count request: \(request)")
            return Self.response(for: request, contentRange: "*/0")
        }

        let counts = try await makeService().loadCounts(
            userId: "profile-id",
            accessToken: "session-token"
        )

        XCTAssertEqual(counts, ProfileFollowCounts(followers: 2, following: 3))
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer session-token"
        })
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Prefer") == "count=exact"
        })
    }

    func testCountFallsBackToReturnedRowsWhenContentRangeIsMissing() async throws {
        ProfileFollowURLProtocol.handler = { request in
            let body = #"[{"follower_id":"1"},{"follower_id":"2"}]"#
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        let counts = try await makeService().loadCounts(
            userId: "profile-id",
            accessToken: nil
        )

        XCTAssertEqual(counts, ProfileFollowCounts(followers: 2, following: 2))
    }

    // Список подписчиков: фильтр по following_id, люди — follower_id,
    // профили приходят в любом порядке, а показываем в порядке подписок.
    func testFollowersListKeepsFollowOrderAndSkipsDeletedProfiles() async throws {
        let recorder = ProfileFollowRequestRecorder()
        ProfileFollowURLProtocol.handler = { request in
            recorder.record(request)
            let url = try XCTUnwrap(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

            if url.path.hasSuffix("/rest/v1/followers") {
                XCTAssertEqual(value("following_id"), "eq.profile-id")
                XCTAssertNil(value("follower_id"))
                XCTAssertEqual(value("order"), "created_at.desc,id.desc")
                XCTAssertEqual(value("offset"), "0")
                XCTAssertEqual(value("limit"), "3")
                let body = #"""
                [{"follower_id":"b","following_id":"profile-id"},
                 {"follower_id":"a","following_id":"profile-id"},
                 {"follower_id":"gone","following_id":"profile-id"}]
                """#
                return Self.json(for: request, body)
            }
            if url.path.hasSuffix("/rest/v1/profiles") {
                XCTAssertEqual(value("id"), "in.(b,a,gone)")
                XCTAssertEqual(value("select"), ProfileFollowService.listProfileSelect)
                let body = #"[{"id":"a","name":"Анна"},{"id":"b","nickname":"bob"}]"#
                return Self.json(for: request, body)
            }
            XCTFail("Unexpected request: \(request)")
            return Self.json(for: request, "[]")
        }

        let page = try await makeService().loadList(
            .followers,
            userId: "profile-id",
            accessToken: "session-token",
            offset: 0,
            limit: 3
        )

        XCTAssertEqual(page.people.map(\.id), ["b", "a"])
        XCTAssertTrue(page.hasMore, "full page means there may be more rows")
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer session-token"
        })
    }

    // Подписки: фильтр по follower_id, люди — following_id; пустой ответ —
    // без второго запроса и без «ещё».
    func testFollowingListUsesFollowerColumnAndStopsOnEmptyPage() async throws {
        let recorder = ProfileFollowRequestRecorder()
        ProfileFollowURLProtocol.handler = { request in
            recorder.record(request)
            let url = try XCTUnwrap(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(url.path.hasSuffix("/rest/v1/followers"))
            XCTAssertTrue(items.contains { $0.name == "follower_id" && $0.value == "eq.profile-id" })
            XCTAssertEqual(items.first { $0.name == "offset" }?.value, "30")
            return Self.json(for: request, "[]")
        }

        let page = try await makeService().loadList(
            .following,
            userId: "profile-id",
            accessToken: nil,
            offset: 30,
            limit: 30
        )

        XCTAssertEqual(page, ProfileFollowPage(people: [], hasMore: false))
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNil(recorder.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testFollowListSurfacesServerErrors() async {
        ProfileFollowURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await makeService().loadList(.followers, userId: "profile-id", accessToken: nil)
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? ProfileFollowServiceError, .http(statusCode: 500))
        }
    }

    private static func json(for request: URLRequest, _ body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private func makeService() -> ProfileFollowService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileFollowURLProtocol.self]
        return ProfileFollowService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "test-anon-key"
        )
    }

    private static func response(
        for request: URLRequest,
        contentRange: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "Content-Range": contentRange
            ]
        )!
        return (response, Data(#"[{"follower_id":"placeholder"}]"#.utf8))
    }
}

private final class ProfileFollowRequestRecorder {
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

private final class ProfileFollowURLProtocol: URLProtocol {
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
