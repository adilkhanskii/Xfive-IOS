import XCTest

/// QA-скрины 390 pt: страница задания с 8 откликами — обычный аккаунт видит
/// только число, аккаунт Адильхана — список. Только ручной прогон:
/// TEST_RUNNER_X5_TASK_SHOT=1; экран открывает DEBUG-флаг (без входа и сети).
final class TaskRespondersShotTests: XCTestCase {
    private let ruArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_KZ", "-x5.language", "ru"]
    private let adilkhanUserId = "eee55a08-18d1-46e3-a303-1411d1bb9333"

    func testRegularUserSeesOnlyTheCount() throws {
        try requireManualRun()
        continueAfterFailure = true
        let app = launch(user: "qa-viewer")
        XCTAssertTrue(label("(8)", in: app).waitForExistence(timeout: 40), "response count did not appear")
        sleep(2)
        XCTAssertFalse(label("Айдана", in: app).exists, "regular user must not see responders")
        attach(app, "responders-ios-regular")
    }

    func testOwnerSeesTheResponders() throws {
        try requireManualRun()
        continueAfterFailure = true
        let app = launch(user: adilkhanUserId)
        XCTAssertTrue(label("(8)", in: app).waitForExistence(timeout: 40), "response count did not appear")
        XCTAssertTrue(label("Айдана", in: app).waitForExistence(timeout: 20), "owner must see responders")
        sleep(2)
        attach(app, "responders-ios-owner")
    }

    private func launch(user: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ruArguments
        app.launchEnvironment["X5_TASK_QA_PREVIEW"] = "1"
        app.launchEnvironment["X5_TASK_QA_USER"] = user
        app.launch()
        return app
    }

    private func label(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func requireManualRun() throws {
        guard ProcessInfo.processInfo.environment["X5_TASK_SHOT"] == "1" else {
            throw XCTSkip("manual screenshot run only")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
