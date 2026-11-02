import XCTest
import CutlineCore

extension EditorUITests {
    func testSettingsKeepAKeyForEachAIProviderAndListSounds() throws {
        launch()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.textFields["branding.kick"].waitForExistence(timeout: 5), "Settings open on General")
        app.toolbars.buttons["AI"].click()
        let provider = app.popUpButtons["settings.aiProvider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        let claudeKey = app.secureTextFields["settings.key.claude"]
        XCTAssertTrue(claudeKey.waitForExistence(timeout: 5))
        claudeKey.click(); claudeKey.typeText("sk-ant-test-only")
        app.buttons["settings.saveKey.claude"].click()
        XCTAssertTrue(app.buttons["settings.removeKey.claude"].waitForExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("test-credential-claude"), encoding: .utf8), "sk-ant-test-only")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("test-credential").path), "The OpenRouter key is separate")
        app.buttons["settings.removeKey.claude"].click()
        XCTAssertTrue(claudeKey.waitForExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("test-credential-claude").path))
        app.toolbars.buttons["Sounds"].click()
        XCTAssertTrue(app.buttons["settings.importPack"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); screenshot.name = "Sounds settings"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
