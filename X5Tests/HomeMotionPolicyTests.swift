import XCTest
@testable import X5

final class HomeMotionPolicyTests: XCTestCase {
    func testMotionCatalogAnimatesOnlyTheHeroAndVideoMarkedMedia() {
        XCTAssertEqual(
            HomeMotionCatalog.asset(for: "HomeCoverTargetAds"),
            HomeMotionAsset(
                source: .bundled(resourceName: "HomeMotionStudio"),
                posterAssetName: "HomeMotionStudioPoster"
            )
        )
        XCTAssertEqual(
            HomeMotionCatalog.asset(for: "HomeTrendFruitVideo"),
            HomeMotionAsset(
                source: .bundled(resourceName: "HomeMotionFruit"),
                posterAssetName: "HomeMotionFruitPoster"
            )
        )
        XCTAssertEqual(
            HomeMotionCatalog.asset(for: "HomeUtilityVideo"),
            HomeMotionAsset(
                source: .bundled(resourceName: "HomeMotionStudio"),
                posterAssetName: "HomeMotionStudioPoster"
            )
        )
        XCTAssertEqual(
            HomeMotionCatalog.asset(for: "HomeTrendLiveVideo"),
            HomeMotionAsset(
                source: .bundled(resourceName: "HomeTrendStrawberry"),
                posterAssetName: "HomeTrendLiveVideo"
            )
        )
        XCTAssertEqual(
            HomeMotionCatalog.asset(for: "HomeTrendPost"),
            HomeMotionAsset(
                source: .bundled(resourceName: "HomeTrendTokayev"),
                posterAssetName: "HomeTrendPost"
            )
        )
        XCTAssertNil(HomeMotionCatalog.asset(for: "HomeCoverYoutube"))
    }

    func testPlaybackRunsOnlyWhenActiveVisibleForegroundMotionAllowedAndNotLowPower() {
        XCTAssertTrue(
            HomeMotionPlaybackPolicy.shouldPlay(
                isActive: true,
                isVisible: true,
                appIsActive: true,
                reduceMotion: false,
                lowPowerMode: false
            )
        )
        XCTAssertFalse(
            HomeMotionPlaybackPolicy.shouldPlay(
                isActive: false,
                isVisible: true,
                appIsActive: true,
                reduceMotion: false,
                lowPowerMode: false
            )
        )
        XCTAssertFalse(
            HomeMotionPlaybackPolicy.shouldPlay(
                isActive: true,
                isVisible: false,
                appIsActive: true,
                reduceMotion: false,
                lowPowerMode: false
            )
        )
        XCTAssertFalse(
            HomeMotionPlaybackPolicy.shouldPlay(
                isActive: true,
                isVisible: true,
                appIsActive: false,
                reduceMotion: false,
                lowPowerMode: false
            )
        )
        XCTAssertFalse(
            HomeMotionPlaybackPolicy.shouldPlay(
                isActive: true,
                isVisible: true,
                appIsActive: true,
                reduceMotion: true,
                lowPowerMode: false
            )
        )
        XCTAssertFalse(
            HomeMotionPlaybackPolicy.shouldPlay(
                isActive: true,
                isVisible: true,
                appIsActive: true,
                reduceMotion: false,
                lowPowerMode: true
            )
        )
    }

    func testUserInitiatedPlaybackRunsWithReduceMotionAndLowPowerEnabled() {
        XCTAssertTrue(
            HomeMotionPlaybackPolicy.shouldPlay(
                isActive: true,
                isVisible: true,
                appIsActive: true,
                reduceMotion: true,
                lowPowerMode: true,
                isUserInitiated: true
            )
        )
    }
}
