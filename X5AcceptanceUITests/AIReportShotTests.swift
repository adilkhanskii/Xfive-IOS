import XCTest

/// QA-скрины 390 pt: кнопка «Пожаловаться» под результатом ИИ, форма жалобы,
/// «спасибо» после отправки. Только ручной прогон: TEST_RUNNER_X5_AI_REPORT_SHOT=1;
/// экран открывает DEBUG-флаг (без входа и сети, отправка в QA не уходит на сервер).
final class AIReportShotTests: XCTestCase {
    func testReportFlowScreens() throws {
        guard ProcessInfo.processInfo.environment["X5_AI_REPORT_SHOT"] == "1" else {
            throw XCTSkip("manual screenshot run only")
        }
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_KZ", "-x5.language", "ru"]
        app.launchEnvironment["X5_AI_REPORT_QA"] = "1"
        app.launch()

        let button = app.buttons["ai.report.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 40), "report button did not appear")
        sleep(2)
        attach(app, "ai-report-ios-1-button")

        button.tap()
        let reason = app.buttons["ai.report.reason.sexual"]
        XCTAssertTrue(reason.waitForExistence(timeout: 20), "report sheet did not open")
        reason.tap()
        sleep(1)
        attach(app, "ai-report-ios-2-form")

        app.buttons["ai.report.send"].tap()
        XCTAssertTrue(app.buttons["ai.report.done"].waitForExistence(timeout: 20), "thank-you state did not appear")
        sleep(1)
        attach(app, "ai-report-ios-3-sent")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
