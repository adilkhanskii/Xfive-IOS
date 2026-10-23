import XCTest

/// Real app and network, not X5_HOME_QA_PREVIEW. No account creation, purchase,
/// generation, publication or message sending. Only the dedicated review login.
final class AcceptanceSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-x5.language", "en"]
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            recordBlockingSurfaces()
            capture("failure-last-screen")
        }
        app.terminate()
    }

    private func recordBlockingSurfaces() {
        // Never publish arbitrary alert bodies, credentials or account fields.
        let knownKinds = ["notification", "local network", "paste", "track", "save password",
                          "apple account", "apple id", "itunes", "sign in", "photos",
                          "microphone", "face id", "keychain"]
        let knownButtons: Set<String> = ["Don’t Allow", "Don't Allow", "Allow", "OK", "Cancel",
                                         "Sign In", "Continue", "Settings", "Not Now"]
        for (name, surface) in [("app", app!),
                                ("system", XCUIApplication(bundleIdentifier: "com.apple.springboard"))] {
            let alerts = surface.alerts.allElementsBoundByIndex
            let sheets = surface.sheets.allElementsBoundByIndex
            print("Blocking surfaces \(name): state=\(surface.state.rawValue), alerts=\(alerts.count), sheets=\(sheets.count), keyboards=\(surface.keyboards.count)")
            for alert in (alerts + sheets).prefix(6) {
                let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label))
                    .joined(separator: " ").lowercased()
                let kinds = knownKinds.filter { text.contains($0) }
                let buttons = alert.buttons.allElementsBoundByIndex.map { button in
                    knownButtons.contains(button.label) ? button.label : "other"
                }
                print("Alert category=\(kinds), buttons=\(buttons), frame=\(alert.frame)")
                for scroll in alert.scrollViews.allElementsBoundByIndex {
                    print("Modal scroll frame=\(scroll.frame), hittable=\(scroll.isHittable)")
                }
            }
        }
    }

    private func dismissPasswordSaveOffer() {
        // Observed OS AutoFill sheet in run 34108314479, not an app Store error.
        // Never save review credentials on the runner or dismiss unknown sheets.
        let saveOffer = app.sheets["Save Password?"]
        if saveOffer.waitForExistence(timeout: 5) {
            let notNow = saveOffer.buttons["Not Now"]
            XCTAssertTrue(notNow.isHittable, "The identified AutoFill offer must be dismissible")
            notNow.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: saveOffer)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            print("Identified AutoFill Save Password offer declined")
        }
    }

    private func scrollContentUp(_ scroll: XCUIElement, above tabBar: XCUIElement) {
        // Both the app and ScrollView frames can extend underneath the floating
        // system tab bar. Drive a real drag inside the observed content viewport;
        // never replace a non-hittable Store button with a coordinate tap.
        let window = app.frame
        let frame = scroll.frame.intersection(window)
        let contentBottom = min(frame.maxY, tabBar.frame.minY)
        let contentHeight = contentBottom - frame.minY
        XCTAssertEqual(app.keyboards.count, 0, "Login keyboard must not cover Profile")
        XCTAssertEqual(app.alerts.count, 0, "Unexpected modal blocks Profile")
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0,
                       "Unexpected system modal blocks Profile")
        XCTAssertGreaterThan(contentHeight, 200, "A visible scroll viewport is required")
        print("Scroll viewport=\(frame), tab bar=\(tabBar.frame)")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frame.midX - window.minX,
                                               dy: frame.minY + contentHeight * 0.75 - window.minY))
        let end = origin.withOffset(CGVector(dx: frame.midX - window.minX,
                                             dy: frame.minY + contentHeight * 0.30 - window.minY))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    func test01GuestValidationAndBack() throws {
        let emailChoice = app.buttons["Continue with Email"]
        XCTAssertTrue(emailChoice.waitForExistence(timeout: 30))
        capture("A01-login-options")
        emailChoice.tap()
        let email = app.textFields.firstMatch
        let password = app.secureTextFields.firstMatch
        let submit = app.buttons["Sign in to Xfive marketing"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        XCTAssertFalse(submit.isEnabled)
        email.tap()
        email.typeText("invalid-email")
        password.tap()
        password.typeText("not-a-real-password")
        XCTAssertFalse(submit.isEnabled)
        app.buttons["Back"].tap()
        XCTAssertTrue(emailChoice.waitForExistence(timeout: 5))
        emailChoice.tap()
        XCTAssertEqual(email.value as? String, "Email")
        XCTAssertFalse(submit.isEnabled)
        capture("A01-invalid-input-cleared")
        app.buttons["Back"].tap()
    }

    func test02ReviewLoginReadOnlyScreensAndSessionPersistence() throws {
        let emailChoice = app.buttons["Continue with Email"]
        XCTAssertTrue(emailChoice.waitForExistence(timeout: 30))
        emailChoice.tap()
        let bundle = Bundle(for: Self.self)
        func credential(_ name: String) throws -> String {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "txt"))
            return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText(try credential("demo_user"))
        app.secureTextFields.firstMatch.tap()
        app.secureTextFields.firstMatch.typeText(try credential("demo_password"))
        app.buttons["Sign in to Xfive marketing"].tap()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "Real review login must finish profile routing")
        // The OS notification permission sheet can swallow the first tab tap.
        // Deny notifications in this read-only run; never silently grant access.
        let systemAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if systemAlert.waitForExistence(timeout: 10) {
            let deny = systemAlert.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
            XCTAssertTrue(deny.exists, "Unexpected system permission sheet requires investigation")
            deny.tap()
        }
        dismissPasswordSaveOffer()
        capture("A02-authenticated-home")

        let profileTab = tabs.buttons["Profile"]
        profileTab.tap()
        let profileSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: profileTab)
        XCTAssertEqual(XCTWaiter.wait(for: [profileSelected], timeout: 10), .completed,
                       "Profile navigation must complete before looking for Store")
        dismissPasswordSaveOffer()
        recordBlockingSurfaces()
        XCTAssertEqual(app.sheets.count, 0, "Unknown application sheet requires investigation before scrolling")
        let storePredicate = NSPredicate(format: "label BEGINSWITH %@", "Store")
        let scrolls = app.scrollViews.allElementsBoundByIndex
        for (index, scroll) in scrolls.enumerated() {
            print("Scroll owner \(index): frame=\(scroll.frame), hittable=\(scroll.isHittable), storeDescendants=\(scroll.buttons.matching(storePredicate).count)")
        }
        XCTAssertEqual(app.alerts.count, 0, "Unexpected application modal blocks Profile")
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0,
                       "Unexpected system modal blocks Profile")
        // An arbitrary first ScrollView can belong to an alert or social strip.
        // Locate the owner by the actual Store descendant, not by screen position.
        let storeOwners = scrolls.filter { $0.buttons.matching(storePredicate).count > 0 }
        XCTAssertEqual(storeOwners.count, 1, "Store must have one unambiguous scroll owner")
        let profileScroll = try XCTUnwrap(storeOwners.first)
        print("Profile scroll geometry: frame=\(profileScroll.frame), hittable=\(profileScroll.isHittable)")
        let store = profileScroll.buttons.matching(storePredicate).firstMatch
        for attempt in 0..<4 where !store.isHittable {
            // Geometry only: never log the account's balance or profile label.
            print("Store before swipe \(attempt): exists=\(store.exists), frame=\(store.frame)")
            scrollContentUp(profileScroll, above: tabs)
        }
        XCTAssertTrue(store.waitForExistence(timeout: 10))
        XCTAssertTrue(store.isHittable, "Visible Store must accept a native tap; frame=\(store.frame)")
        store.tap()
        XCTAssertTrue(app.navigationBars["Store"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1000 credits"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2000 credits"].exists)
        capture("P01-store-packs-no-purchase")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["5000 credits"].waitForExistence(timeout: 5))
        capture("P01-store-third-pack-no-purchase")
        app.buttons["Done"].tap()

        tabs.buttons["Hub"].tap()
        XCTAssertTrue(app.staticTexts["Hub"].waitForExistence(timeout: 10))
        capture("H01-hub-read-only")
        tabs.buttons["CourseUP"].tap()
        XCTAssertTrue(app.staticTexts["No published courses yet"].waitForExistence(timeout: 30),
                      "The review account currently has zero published courses; never substitute invented lessons")
        XCTAssertFalse(app.staticTexts["Вайбкодинг для маркетолога"].exists)
        app.buttons["Refresh"].tap()
        XCTAssertTrue(app.staticTexts["No published courses yet"].waitForExistence(timeout: 30))
        capture("C01-course-catalog-read-only")
        app.terminate()
        app.launch()
        let restored = app.tabBars.firstMatch.waitForExistence(timeout: 60)
        capture("A02-cold-restart-result")
        XCTAssertTrue(restored)
        XCTAssertFalse(app.buttons["Continue with Email"].exists)
        capture("A02-session-restored")
    }
}
