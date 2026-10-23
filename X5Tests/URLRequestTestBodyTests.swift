import Foundation
import XCTest

final class URLRequestTestBodyTests: XCTestCase {
    func testMaterializesBodyStreamWithoutChangingRequestMetadata() throws {
        let expectedBody = Data(#"{"request_id":"test"}"#.utf8)
        var request = URLRequest(url: URL(string: "https://example.com/test")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBodyStream = InputStream(data: expectedBody)

        let materialized = try request.materializingHTTPBodyForTesting()

        XCTAssertEqual(materialized.httpBody, expectedBody)
        XCTAssertNil(materialized.httpBodyStream)
        XCTAssertEqual(materialized.httpMethod, "POST")
        XCTAssertEqual(
            materialized.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(materialized.url, request.url)
    }

    func testKeepsExistingHTTPBodyUnchanged() throws {
        let expectedBody = Data(#"{"request_id":"existing"}"#.utf8)
        var request = URLRequest(url: URL(string: "https://example.com/test")!)
        request.httpBody = expectedBody

        let materialized = try request.materializingHTTPBodyForTesting()

        XCTAssertEqual(materialized.httpBody, expectedBody)
    }
}
