import XCTest

/// QA-скрины 390 pt: форма «Новое задание» с заполненным автосообщением и чат
/// со ссылками. Только ручной прогон: TEST_RUNNER_X5_CREATE_TASK_SHOT=1; экраны
/// открывают DEBUG-флаги (без входа, без сети, ничего не публикуют).
final class CreateTaskAutoMessageShotTests: XCTestCase {
    private let ruArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_KZ", "-x5.language", "ru"]

    func testCreateTaskFormWithFilledAutoMessage() throws {
        try requireManualRun()
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ruArguments
        app.launchEnvironment["X5_CREATE_TASK_QA_PREVIEW"] = "1"
        app.launchEnvironment["X5_CREATE_TASK_QA_AUTOMESSAGE"] = "Здравствуйте! Спасибо за отклик. Пришлите портфолио и сроки"
        app.launch()

        XCTAssertTrue(app.textFields["Заголовок"].waitForExistence(timeout: 40), "create task form did not open")
        // Клавиатуру не открываем, листаем саму форму (Form = UICollectionView).
        let form = app.collectionViews.firstMatch
        for _ in 0..<6 {
            form.swipeUp()
        }
        sleep(1)
        attach(app, "automsg-ios-form")
    }

    func testChatShowsTappableLinksOnBothBubbleColors() throws {
        try requireManualRun()
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ruArguments
        app.launchEnvironment["X5_CHAT_QA_PREVIEW"] = "1"
        app.launch()

        let brief = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Бриф здесь"))
            .firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 40), "mock chat did not open")
        sleep(2)
        attach(app, "links-ios-chat")
    }

    private func requireManualRun() throws {
        guard ProcessInfo.processInfo.environment["X5_CREATE_TASK_SHOT"] == "1" else {
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
