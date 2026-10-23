import XCTest
@testable import X5

final class CoursePurchaseResponseTests: XCTestCase {
    func testDecodesPurchasedResponse() throws {
        let response = try decode(
            """
            {
              "status": "purchased",
              "course_id": "course-paid",
              "credits_remaining": 50000,
              "course_price": 50000,
              "charged_amount": 50000
            }
            """
        )

        XCTAssertEqual(response.status, .purchased)
        XCTAssertEqual(response.courseId, "course-paid")
        XCTAssertEqual(response.creditsRemaining, 50_000)
        XCTAssertEqual(response.coursePrice, 50_000)
        XCTAssertEqual(response.chargedAmount, 50_000)
    }

    func testDecodesAlreadyOwnedResponse() throws {
        let response = try decode(
            """
            {
              "status": "already_owned",
              "course_id": "course-paid",
              "credits_remaining": 50000
            }
            """
        )

        XCTAssertEqual(response.status, .alreadyOwned)
        XCTAssertEqual(response.courseId, "course-paid")
        XCTAssertEqual(response.creditsRemaining, 50_000)
    }

    func testDecodesInsufficientCreditsResponse() throws {
        let response = try decode(
            """
            {
              "status": "insufficient_credits",
              "course_id": "course-paid",
              "credits_remaining": 10000
            }
            """
        )

        XCTAssertEqual(response.status, .insufficientCredits)
        XCTAssertEqual(response.courseId, "course-paid")
        XCTAssertEqual(response.creditsRemaining, 10_000)
    }

    func testDecodesPriceChangedWithoutGrantingOwnership() throws {
        let response = try decode(
            """
            {
              "status": "price_changed",
              "course_id": "course-paid",
              "credits_remaining": 100000,
              "course_price": 75000,
              "charged_amount": 0
            }
            """
        )

        XCTAssertEqual(response.status, .priceChanged)
        XCTAssertEqual(response.coursePrice, 75_000)
        XCTAssertEqual(response.chargedAmount, 0)
        XCTAssertFalse(response.grantsOwnership)
        XCTAssertEqual(response.reconciledExpectedPrice(currentPrice: 50_000), 75_000)
    }

    func testMissingPriceChangePayloadKeepsPreviouslyConfirmedPrice() throws {
        let response = try decode(
            """
            {
              "status": "price_changed",
              "course_id": "course-paid",
              "credits_remaining": 100000,
              "charged_amount": 0
            }
            """
        )

        XCTAssertEqual(response.reconciledExpectedPrice(currentPrice: 50_000), 50_000)
    }

    private func decode(_ json: String) throws -> CoursePurchaseResponse {
        try JSONDecoder().decode(CoursePurchaseResponse.self, from: Data(json.utf8))
    }
}
