import XCTest
@testable import X5

/// SDK Meta не должен стартовать с пустым/незаполненным App ID или без токена.
final class MetaAnalyticsConfigTests: XCTestCase {
    func testEmptyOrUnexpandedIDsKeepSDKOff() {
        XCTAssertNil(MetaAnalytics.configuredAppID(in: nil))
        XCTAssertNil(MetaAnalytics.configuredAppID(in: [:]))
        XCTAssertNil(MetaAnalytics.configuredAppID(in: [
            "FacebookAppID": "", "FacebookClientToken": "abc",
        ]))
        XCTAssertNil(MetaAnalytics.configuredAppID(in: [
            "FacebookAppID": "$(FACEBOOK_APP_ID)", "FacebookClientToken": "abc",
        ]))
        XCTAssertNil(MetaAnalytics.configuredAppID(in: [
            "FacebookAppID": "1234567890", "FacebookClientToken": "",
        ]))
        XCTAssertNil(MetaAnalytics.configuredAppID(in: [
            "FacebookAppID": "1234567890", "FacebookClientToken": "$(FACEBOOK_CLIENT_TOKEN)",
        ]))
    }

    func testNumericAppIDWithTokenTurnsSDKOn() {
        XCTAssertEqual(
            MetaAnalytics.configuredAppID(in: [
                "FacebookAppID": " 1234567890 ", "FacebookClientToken": "abc",
            ]),
            "1234567890"
        )
    }

    func testTestBundleHasNoMetaIDsSoSDKIsOff() {
        // Debug/CI: FACEBOOK_APP_ID пуст → приложение работает без Meta.
        XCTAssertFalse(MetaAnalytics.isConfigured)
    }
}
