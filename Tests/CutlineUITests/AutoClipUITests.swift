import XCTest
import CutlineCore

extension EditorUITests {
    func prepareAutoClipRecording() throws {
        try CreatorProfileStore.save(ShortBranding(text: "example.test/player"), to: root)
        let media = MediaItem(url: fixture.appendingPathComponent("autoclip.mp4"), duration: 12)
        project.media = [media]; project.media[0].audioTrackCount = 2
        project.shortHook = "Watch this play"; project.media[0].shortFraming = ShortFraming(); project.media[0].shortFraming?.confirmed = true
        project.clips = [TimelineClip(mediaID: media.id, sourceOut: 12)]; project.captionTrack = nil; project.transcripts = nil
        try project.write(to: projectURL)
    }
    func scanAutomaticClips() {
        let button = app.buttons["clips.scan"]; reveal(button, panel: "clips.scroll"); button.click()
        assertLabel("clips.status", "Found 1 clip to review.", timeout: 40)
    }
    func testAutomaticClipsEmptyLibrary() {
        launch(project: false); tab("Clips")
        XCTAssertTrue(app.staticTexts["clips.empty"].exists); XCTAssertFalse(app.buttons["clips.scan"].exists)
    }
    func testAutomaticClipScanPreviewAppendAndUndo() throws {
        try prepareAutoClipRecording(); launch(); tab("Clips"); scanAutomaticClips()
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'clips.preview.'")).firstMatch
        reveal(preview, panel: "clips.scroll"); preview.click()
        waitEnabled(app.buttons["clips.previewPlay"]); app.buttons["clips.previewPlay"].click()
        app.buttons["Done"].click()
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'clips.add.'")).firstMatch
        reveal(add, panel: "clips.scroll"); add.click()
        XCTAssertEqual(try save().clips.count, 2)
        app.typeKey("z", modifierFlags: .command); XCTAssertEqual(try save().clips, project.clips)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-log").path), "The local scanner must not call OpenRouter")
    }
    func testAutomaticClipsSelectionAndNativeBatchExport() throws {
        try prepareAutoClipRecording(); launch(); tab("Clips"); scanAutomaticClips()
        let clear = app.buttons["clips.clear"]; reveal(clear, panel: "clips.scroll"); clear.click()
        XCTAssertFalse(app.buttons["clips.export"].isEnabled)
        app.buttons["clips.selectAll"].click()
        let export = app.buttons["clips.export"]; reveal(export, panel: "clips.scroll"); export.click(); chooseFile(root)
        assertLabel("clips.status", "Exported 1 clip.", timeout: 40)
        XCTAssertTrue(app.buttons["clips.showOutput"].exists)
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("Cutline clips ") })
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "mp4" }.count, 1)
        XCTAssertEqual(files.filter { $0.pathExtension == "cutline" }.count, 1)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "analysis.json" })
        XCTAssertEqual(try save().clips, project.clips)
    }
    func testAutomaticClipsQuietTrackProducesEmptyResult() throws {
        try prepareAutoClipRecording(); launch(); tab("Clips")
        tapInPanel(app.checkBoxes["clips.vision"])
        tapInPanel(app.popUpButtons["clips.track"]); app.menuItems["Track 2"].click()
        let scan = app.buttons["clips.scan"]; reveal(scan, panel: "clips.scroll"); scan.click()
        assertLabel("clips.status", "No clips met these rules. Try another track or adjust the thresholds.", timeout: 30)
        XCTAssertFalse(app.buttons["clips.export"].exists)
    }
    func testAutomaticClipsValidateRulesAndOpenCalibration() throws {
        try prepareAutoClipRecording(); launch(); tab("Clips")
        let regions = app.buttons["clips.regions"]; reveal(regions, panel: "clips.scroll"); regions.click()
        XCTAssertTrue(app.sliders["clips.regionTime"].waitForExistence(timeout: 5)); app.buttons["Done"].click()
        toggleDisclosure("Sensitivity & timing")
        edit(app.textFields["clips.maximum"], "3", submit: true)
        let scan = app.buttons["clips.scan"]; reveal(scan, panel: "clips.scroll"); scan.click()
        textExists("Check scan thresholds"); app.sheets.buttons["OK"].firstMatch.click()
        XCTAssertFalse(app.buttons["clips.cancel"].exists)
    }
}
