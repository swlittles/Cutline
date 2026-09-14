import XCTest
import CutlineCore

extension EditorUITests {
    func testNewProjectDefaultsToMobileShortWithRequiredHookControl() {
        launch(project: false)
        XCTAssertTrue(app.buttons["workflow.mobileShort"].exists)
        XCTAssertTrue(app.textFields["short.hook"].exists)
        XCTAssertFalse(app.buttons["short.framing"].isEnabled)
    }
    func testShortWorkflowAndHookPersistAcrossReopen() throws {
        launch(); app.buttons["workflow.mobileShort"].click()
        edit(app.textFields["short.hook"], "Would you make this play?")
        let saved = try save(); XCTAssertEqual(saved.workflow, .mobileShort); XCTAssertEqual(saved.outputFormat, .portrait)
        XCTAssertEqual(saved.shortHook, "Would you make this play?")
        app.terminate(); launch(); XCTAssertEqual(app.textFields["short.hook"].value as? String, "Would you make this play?")
        app.buttons["workflow.youtubeVideo"].click()
        XCTAssertEqual(try save().outputFormat, .landscape)
    }
    func testShortExportRejectsMissingHookBeforeFilePicker() {
        launch(); app.buttons["workflow.mobileShort"].click(); waitEnabled(app.buttons["project.export"]); app.buttons["project.export"].click()
        textExists("Every short needs an on-screen hook")
    }
    func testShortFramingCanBeEditedConfirmedAndSaved() throws {
        launch(); app.buttons["workflow.mobileShort"].click()
        let framing = app.buttons["short.framing"]; reveal(framing, panel: "inspector.scroll"); framing.click()
        XCTAssertTrue(app.textFields["short.Facecam.X"].waitForExistence(timeout: 5))
        edit(app.textFields["short.Facecam.X"], "5", submit: false)
        app.checkBoxes["short.confirmed"].click(); app.buttons["short.applyFraming"].click()
        let saved = try save()
        XCTAssertEqual(saved.media[0].shortFraming?.camera.x ?? -1, 0.05, accuracy: 0.001)
        XCTAssertEqual(saved.media[0].shortFraming?.confirmed, true)
    }
}
