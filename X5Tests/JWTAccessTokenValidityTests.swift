import XCTest
@testable import X5

final class JWTAccessTokenValidityTests: XCTestCase {
    func testTokenWithEnoughLifetimeDoesNotNeedRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try makeUnsignedToken(expiration: now.addingTimeInterval(1_800))

        XCTAssertFalse(
            JWTAccessTokenValidity.needsRefresh(
                token,
                now: now,
                minimumValidity: 600
            )
        )
    }

    func testTokenNearExpiryNeedsRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try makeUnsignedToken(expiration: now.addingTimeInterval(300))

        XCTAssertTrue(
            JWTAccessTokenValidity.needsRefresh(
                token,
                now: now,
                minimumValidity: 600
            )
        )
    }

    func testMalformedTokenFailsClosed() {
        XCTAssertTrue(
            JWTAccessTokenValidity.needsRefresh(
                "not-a-jwt",
                now: Date(),
                minimumValidity: 600
            )
        )
    }

    private func makeUnsignedToken(expiration: Date) throws -> String {
        let payload = try JSONSerialization.data(
            withJSONObject: ["exp": Int(expiration.timeIntervalSince1970)]
        )
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
