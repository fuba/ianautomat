import XCTest

final class ControlCenterTests: XCTestCase {
    @MainActor func testDraftPersistsAndConnectionIsRequired() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
        let goal = app.textViews["goal-editor"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["start-goal"].isEnabled)
        goal.tap()
        let draft = "Weekend checklist " + UUID().uuidString.prefix(6)
        goal.typeText(String(draft))
        let savedDraft = goal.value as? String
        XCTAssertTrue(savedDraft?.contains(draft) == true)
        app.terminate()
        app.launch()
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        XCTAssertEqual(goal.value as? String, savedDraft)
        XCTAssertTrue(app.buttons["connect-chatgpt"].exists)
    }
}

extension ControlCenterTests {
    @MainActor func testChatGPTUsesSystemAuthenticationSession() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
        let connect = app.buttons["connect-chatgpt"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = system.alerts.firstMatch
        guard prompt.waitForExistence(timeout: 10) else {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("The system did not show the authentication consent prompt.")
            return
        }
        XCTAssertTrue(prompt.staticTexts.allElementsBoundByIndex.contains {
            $0.label.contains("openai.com")
        })
        let cancel = prompt.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "キャンセル"])).firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
    }
}
