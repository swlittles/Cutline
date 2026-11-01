import XCTest
import CutlineCore

extension EditorUITests {
    /// A saved clipping session: branded, framed, Track 1 = mic (with the fixture's burst).
    func prepareAutoClipRecording(roles: [AudioRole] = [.mic, .ignore], decisions: Bool = false) throws {
        try CreatorProfileStore.save(ShortBranding(kick: "player"), to: root)
        var media = MediaItem(url: fixture.appendingPathComponent("autoclip.mp4"), duration: 12)
        media.audioTrackCount = 2; media.audioRoles = roles
        media.shortFraming = ShortFraming(); media.shortFraming?.confirmed = true
        project.media = [media]; project.clips = []; project.captionTrack = nil; project.transcripts = nil
        project.clipReview = ClipReview(mediaID: media.id)
        if decisions { project.clipReview?.skipped = ["placeholder"] }
        try project.write(to: projectURL)
    }
    func segment(_ picker: String, _ label: String) {
        let option = app.descendants(matching: .any)[picker].firstMatch.radioButtons[label].firstMatch
        if let panel = panelContaining(option) { reveal(option, panel: panel) }
        option.click()
    }
    func waitForMoments(_ text: String = "Found 1 moment to review.") {
        assertLabel("clips.status", text, timeout: 40)
    }

    func testHomeLeadsToGuidedClipperAndEditor() {
        launch(project: false, home: true)
        XCTAssertTrue(app.buttons["home.openEditor"].exists)
        app.buttons["home.clip"].click()
        XCTAssertTrue(app.buttons["import.choose"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["step.continue"].isEnabled, "A recording is required first")
        XCTAssertFalse(app.buttons["step.2"].isEnabled, "Later steps stay locked")
        app.buttons["clipper.home"].click()
        app.buttons["home.openEditor"].click()
        XCTAssertTrue(app.buttons["media.import"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.radioButtons["Clips"].exists, "Clipping lives in the guided flow")
        app.buttons["editor.clipper"].click()
        XCTAssertTrue(app.buttons["import.choose"].waitForExistence(timeout: 5))
    }

    func testGuidedFlowFromImportToExportedShorts() throws {
        launch(project: false, home: true)
        app.buttons["home.clip"].click()
        app.buttons["import.choose"].click(); chooseFile(fixture.appendingPathComponent("autoclip.mp4"))
        waitEnabled(app.buttons["step.continue"]); app.buttons["step.continue"].click()

        // Layout: crops on a real frame; sound has defaults and stays folded away.
        XCTAssertTrue(app.descendants(matching: .any)["setup.frame"].firstMatch.waitForExistence(timeout: 5))
        tapInPanel(app.buttons["setup.changeSound"])
        segment("setup.role.0", "My voice"); segment("setup.role.1", "Not used")
        assertLabel("setup.routes", "Moments are detected from Track 1. Clips play Track 1. Captions listen to Track 1.")
        XCTAssertFalse(app.buttons["setup.continue"].isEnabled, "A badge username is required")
        edit(app.textFields["branding.kick"], "kick.com/player")
        edit(app.textFields["setup.presetName"], "Test layout")
        waitEnabled(app.buttons["setup.continue"]); app.buttons["setup.continue"].click()

        // Pick clips: moments fill in while measuring finishes. Keep never refuses.
        waitForMoments()
        let keep = app.buttons["review.keep"]; XCTAssertTrue(keep.waitForExistence(timeout: 5))
        edit(app.textFields["review.hook"], "Watch this play")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("]", modifierFlags: [])
        app.typeKey("k", modifierFlags: [])
        assertLabel("review.summary", "1 moment · 1 kept · 0 skipped")
        waitEnabled(app.buttons["review.continue"]); app.buttons["review.continue"].click()

        // Export: one button, straight to the default folder.
        let folderLabel = app.staticTexts["export.folder"]; XCTAssertTrue(folderLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(((folderLabel.value as? String) ?? folderLabel.label).hasSuffix(root.lastPathComponent), "Exports default to the export folder without a file dialog")
        waitEnabled(app.buttons["clips.export"]); app.buttons["clips.export"].click()
        assertLabel("export.done", "Exported 1 clip.", timeout: 60)
        let folder = root.appendingPathComponent("autoclip shorts")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        XCTAssertEqual(files, ["01 - Watch this play.mp4", "Editable projects"])
        let clip = try EditProject.read(from: folder.appendingPathComponent("Editable projects/01 - Watch this play.cutline"))
        XCTAssertEqual(clip.shortHook, "Watch this play"); XCTAssertEqual(clip.workflow, .mobileShort)
        XCTAssertEqual(try ScenePresetStore.load(from: root).first?.name, "Test layout")
        XCTAssertEqual(try CreatorProfileStore.load(from: root).kick, "player")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-log").path), "Clipping never calls a network service")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovery/clip-session.cutline").path), "Sessions autosave for Home")

        // The session saves with its decisions and trims.
        app.typeKey("s", modifierFlags: .command)
        let session = root.appendingPathComponent("Session.cutline")
        saveDialog(to: session); assertLabel("editor.status", "Project saved.")
        let saved = try EditProject.read(from: session)
        XCTAssertEqual(saved.clipReview?.kept.count, 1); XCTAssertEqual(saved.clipReview?.ranges.count, 1)
        XCTAssertEqual(saved.media[0].audioRoles, [.mic, .ignore]); XCTAssertEqual(saved.media[0].shortFraming?.confirmed, true)
        XCTAssertTrue(saved.clips.isEmpty)
    }

    func testRememberedLayoutSkipsSetup() throws {
        try CreatorProfileStore.save(ShortBranding(kick: "player"), to: root)
        let preset = ScenePreset(name: "Saved layout", framing: ShortFraming(), audioRoles: [.mic, .ignore], motionRegion: AutoClipSettings().motionRegion)
        try ScenePresetStore.save([preset], to: root)
        launch(project: false, home: true)
        app.buttons["home.clip"].click()
        app.buttons["import.choose"].click(); chooseFile(fixture.appendingPathComponent("autoclip.mp4"))
        let use = app.checkBoxes["import.useLayout"]; XCTAssertTrue(use.waitForExistence(timeout: 10))
        if (use.value as? Bool) != true { tapInPanel(use) }
        waitEnabled(app.buttons["step.continue"]); XCTAssertEqual(app.buttons["step.continue"].label, "Pick clips")
        app.buttons["step.continue"].click()
        waitForMoments()
        XCTAssertEqual(app.buttons["step.1"].value as? String, "Done")
    }

    func testPickClipsQuietTrackMarksAndDetectionSettings() throws {
        // Detection listens to the quiet mic track, so nothing stands out until a moment is added by hand.
        try prepareAutoClipRecording(roles: [.mix, .mic]); launch(clipper: true)
        tapInPanel(app.buttons["review.detection"])
        let vision = app.checkBoxes["clips.vision"]; XCTAssertTrue(vision.waitForExistence(timeout: 5))
        if (vision.value as? Bool) == true { vision.click() }
        app.buttons["detection.done"].click()
        textExists("No moments stood out", timeout: 40)
        XCTAssertFalse(app.buttons["review.continue"].isEnabled)
        app.buttons["review.addMoment"].firstMatch.click()
        let mark = app.buttons["find.mark"]; XCTAssertTrue(mark.waitForExistence(timeout: 5)); mark.click()
        app.buttons["Done"].firstMatch.click()
        waitForMoments()
        tapInPanel(app.buttons["review.detection"])
        app.buttons["detection.advanced"].click()
        reveal(app.textFields["clips.maximum"], panel: "detection.scroll")
        edit(app.textFields["clips.maximum"], "3", submit: true)
        textExists("Check scan thresholds")
        edit(app.textFields["clips.maximum"], "60", submit: true)
        reveal(app.buttons["clips.regions"], panel: "detection.scroll")
        app.buttons["clips.regions"].click()
        XCTAssertTrue(app.sliders["clips.regionTime"].waitForExistence(timeout: 5)); app.buttons["regions.done"].click()
    }

    func testEditingAClipKeepsTheSessionAndReturns() throws {
        try prepareAutoClipRecording(decisions: true); launch(clipper: true)
        let skip = app.buttons["review.skip"]; XCTAssertTrue(skip.waitForExistence(timeout: 40))
        app.typeKey("x", modifierFlags: [])
        assertLabel("review.summary", "1 moment · 0 kept · 1 skipped")
        app.typeKey("z", modifierFlags: .command)
        assertLabel("review.summary", "1 moment · 0 kept · 0 skipped")
        app.typeKey("k", modifierFlags: [])
        assertLabel("review.summary", "1 moment · 1 kept · 0 skipped")
        tapInPanel(app.buttons["review.openEditor"])
        XCTAssertFalse(app.dialogs.firstMatch.waitForExistence(timeout: 1), "Opening a clip never asks to discard the session")
        XCTAssertTrue(app.buttons["media.import"].waitForExistence(timeout: 10))
        assertLabel("timeline.count", "1 clips")
        app.buttons["editor.backToClips"].click()
        assertLabel("review.summary", "1 moment · 1 kept · 0 skipped", timeout: 40)
    }

    func testSimpleEditorHidesAdvancedTools() {
        launch(advanced: false)
        XCTAssertTrue(app.radioButtons["Captions"].exists); XCTAssertFalse(app.radioButtons["Layers"].exists); XCTAssertFalse(app.radioButtons["AI"].exists)
        XCTAssertTrue(app.radioButtons["Advanced"].exists, "Advanced tools are one click away")
        XCTAssertFalse(app.textFields["trim.In"].exists); XCTAssertTrue(app.buttons["Start here"].exists)
    }
}
