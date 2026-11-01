import XCTest
extension EditorUITests {
    func testDevelopmentUpdatesSettingsAndMenuStayDisabled() {
        launch(project: false)
        XCTAssertTrue(app.descendants(matching: .any)["brand.development"].waitForExistence(timeout: 5), "Development builds show a DEV label")
        let applicationMenu = app.menuBars.menuBarItems.element(boundBy: 1)
        applicationMenu.click()
        XCTAssertFalse(app.menuItems["Check for Updates…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["updates.development"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["updates.check"].exists)
    }
}
