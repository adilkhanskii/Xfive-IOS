import XCTest

/// Отказ Apple 5.1.2(i) 04.11 (1.1.21/271): окно ATT должно появиться само при
/// первом запуске — на экране входа, раньше запроса пушей.
/// Запуск только из ios-att-fresh-install.yml (чистый симулятор + тестовые
/// FACEBOOK_APP_ID/TOKEN, иначе SDK выключен и окна нет): TEST_RUNNER_X5_EXPECT_ATT=1.
final class TrackingPromptFreshInstallTests: XCTestCase {
    func testTrackingPromptAppearsOnFirstLaunchBeforeSignIn() throws {
        guard ProcessInfo.processInfo.environment["X5_EXPECT_ATT"] == "1" else {
            throw XCTSkip("needs a fresh simulator and test Meta IDs (ios-att-fresh-install.yml)")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-x5.language", "en"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "ATT prompt did not appear on first launch")
        let title = alert.label.lowercased()
        XCTAssertTrue(title.contains("track"), "first system alert is not ATT: \(alert.label)")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "01-att-prompt-first-launch"
        shot.lifetime = .keepAlways
        add(shot)

        // Ответ пользователя — любой; дальше приложение работает как обычно.
        let deny = alert.buttons["Ask App Not to Track"]
        XCTAssertTrue(deny.exists, "ATT buttons missing")
        deny.tap()

        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3),
                       "another system alert right after ATT on the sign-in screen")
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "02-sign-in-after-att"
        after.lifetime = .keepAlways
        add(after)
    }
}
