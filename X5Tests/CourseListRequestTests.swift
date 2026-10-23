import Foundation
import XCTest
@testable import X5

final class CourseListRequestTests: XCTestCase {
    private let baseURL = URL(string: "https://example.supabase.co")!

    func testDeveloperCourseListUsesBearerAndDoesNotForcePublicFilter() throws {
        let request = try CourseListRequestBuilder.makeRequest(
            baseURL: baseURL,
            anonKey: "anon-key",
            includeHidden: true,
            accessToken: "developer-token"
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer developer-token")
        XCTAssertFalse(try queryItems(in: request).contains { $0.name == "is_public" })
    }

    func testPublicCourseListUsesAnonAccessAndPublicFilter() throws {
        let request = try CourseListRequestBuilder.makeRequest(
            baseURL: baseURL,
            anonKey: "anon-key",
            includeHidden: false,
            accessToken: nil
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(try queryItems(in: request).contains {
            $0.name == "is_public" && $0.value == "eq.true"
        })
    }

    func testHiddenCourseListFailsClosedWithoutDeveloperSession() {
        XCTAssertThrowsError(
            try CourseListRequestBuilder.makeRequest(
                baseURL: baseURL,
                anonKey: "anon-key",
                includeHidden: true,
                accessToken: nil
            )
        ) { error in
            XCTAssertEqual(error as? CourseListRequestError, .missingAccessToken)
        }
    }

    private func queryItems(in request: URLRequest) throws -> [URLQueryItem] {
        let url = try XCTUnwrap(request.url)
        return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }
}
