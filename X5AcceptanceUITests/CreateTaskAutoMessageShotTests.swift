import XCTest

/// Скрин формы «Новое задание» с разделом «Автоматическое сообщение».
/// Только ручной прогон: TEST_RUNNER_X5_CREATE_TASK_SHOT=1; экран открывает
/// DEBUG-флаг X5_CREATE_TASK_QA_PREVIEW (без входа, без сети, ничего не публикует).
final class CreateTaskAutoMessageShotTests: XCTestCase {
    func testCreateTaskFormShowsAutoMessageSection() throws {
        guard ProcessInfo.processInfo.environment["X5_CREATE_TASK_SHOT"] == "1" else {
            throw XCTSkip("manual screenshot run only")
        }
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_KZ", "-x5.language", "ru"]
        app.launchEnvironment["X5_CREATE_TASK_QA_PREVIEW"] = "1"
        app.launch()

        let title = app.textFields["Заголовок"]
        XCTAssertTrue(title.waitForExistence(timeout: 40), "create task form did not open")
        attach(app, "01-form-top")

        // Клавиатуру не открываем, листаем саму форму (Form = UICollectionView).
        let form = app.collectionViews.firstMatch
        let placeholder = "Например: Здравствуйте! Пришлите портфолио и сроки"
        let byText = NSPredicate(
            format: "placeholderValue == %@ OR label == %@ OR value == %@",
            placeholder, placeholder, placeholder
        )
        let field = app.descendants(matching: .any).matching(byText).firstMatch
        for _ in 0..<6 {
            form.swipeUp()
        }
        attach(app, "02-auto-message-empty")

        XCTAssertTrue(field.exists, "auto message field not found")
        if field.exists {
            field.tap()
            field.typeText("Здравствуйте! Пришлите портфолио и сроки. Бриф: www.x5studio.app")
        }
        attach(app, "03-auto-message-filled-keyboard")

        form.swipeDown()
        form.swipeUp()
        attach(app, "04-auto-message-filled")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
