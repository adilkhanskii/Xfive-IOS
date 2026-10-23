import XCTest
@testable import X5

final class HomeRouteTests: XCTestCase {
    func testPrimaryRoutesHaveStableIdentifiers() {
        XCTAssertEqual(
            HomeRoute.imageGeneration(ImageGenerationCatalog.custom).id,
            "image_generation:custom"
        )
        XCTAssertEqual(HomeRoute.aiStudio.id, "ai_studio")
        XCTAssertEqual(HomeRoute.startupChat.id, "startup_chat")
        XCTAssertEqual(HomeRoute.hub.id, "hub")
        XCTAssertEqual(HomeRoute.videoGeneration.id, "video_generation")
        XCTAssertEqual(HomeRoute.aiInfluencer.id, "ai_influencer")
        XCTAssertEqual(HomeRoute.voiceGeneration.id, "voice_generation")
        XCTAssertEqual(HomeRoute.liveFruits.id, "live_fruits")
    }

    func testAIRoutesUseLiveProviderGatingInsteadOfReleasePlaceholders() {
        XCTAssertFalse(HomeRoute.imageGeneration(ImageGenerationCatalog.custom).isReleaseInDevelopment)
        XCTAssertFalse(HomeRoute.aiStudio.isReleaseInDevelopment)
        XCTAssertFalse(HomeRoute.videoGeneration.isReleaseInDevelopment)
        XCTAssertFalse(HomeRoute.aiInfluencer.isReleaseInDevelopment)
        XCTAssertFalse(HomeRoute.voiceGeneration.isReleaseInDevelopment)

        XCTAssertFalse(HomeRoute.startupChat.isReleaseInDevelopment)
        XCTAssertFalse(HomeRoute.liveFruits.isReleaseInDevelopment)
    }

    func testImageRoutesKeepTheirSelectedCategory() {
        let category = ImageGenerationCatalog.categories[0]

        guard case .imageGeneration(let routedCategory) = HomeRoute.imageGeneration(category) else {
            return XCTFail("Expected an image-generation route")
        }

        XCTAssertEqual(routedCategory, category)
    }

    func testBottomNavigationKeepsAllFiveFunctionalTabs() {
        XCTAssertEqual(
            X5AppTab.allCases.map(\.notificationKey),
            ["home", "courses", "chats", "hub", "profile"]
        )
        XCTAssertEqual(
            X5AppTab.allCases.map(\.titleKey),
            ["tab_home", "tab_courses", "tab_chats", "tab_hub", "tab_profile"]
        )
    }

    func testTabNotificationKeysRoundTrip() {
        for tab in X5AppTab.allCases {
            XCTAssertEqual(X5AppTab(notificationKey: tab.notificationKey), tab)
        }
        XCTAssertNil(X5AppTab(notificationKey: "unknown"))
    }
}
