import XCTest

/// QA-скрины 390 pt: форма «Новое задание» с заполненным автосообщением и чат
/// автора: карточка отклика + автосообщение. Только ручной прогон: TEST_RUNNER_X5_CREATE_TASK_SHOT=1; экраны
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

    func testChatShowsTaskCardThenAutoMessage() throws {
        try requireManualRun()
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ruArguments
        app.launchEnvironment["X5_CHAT_QA_PREVIEW"] = "1"
        app.launch()

        // Вид автора: карточка «Отклик по заданию» от исполнителя, под ней автосообщение.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Нужен таргетолог"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 40), "task card did not appear")
        let autoMessage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Пришлите портфолио"))
            .firstMatch
        XCTAssertTrue(autoMessage.waitForExistence(timeout: 20), "auto message did not appear")
        sleep(2)
        attach(app, "card-ios-author")
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
