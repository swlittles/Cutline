import XCTest
import CutlineCore
import AVFoundation

extension EditorUITests {
    func toggleDisclosure(_ name: String) {
        let triangle = app.disclosureTriangles[name]
        if !triangle.exists { XCTAssertTrue(triangle.waitForExistence(timeout: 5)) }
        if let panel = panelContaining(triangle) { reveal(triangle, panel: panel) }
        triangle.click()
    }
    func tapInPanel(_ element: XCUIElement) {
        if let panel = panelContaining(element) { reveal(element, panel: panel) }
        element.click()
    }
    func panelContaining(_ element: XCUIElement) -> String? {
        guard element.exists, app.sheets.count == 0, app.dialogs.count == 0 else { return nil }
        let x = element.frame.midX
        return ["inspector.scroll", "captions.scroll", "ai.scroll", "layers.scroll", "clips.scroll"].first {
            let panel = app.scrollViews[$0]
            return panel.exists && x >= panel.frame.minX && x <= panel.frame.maxX
        }
    }
    func reveal(_ element: XCUIElement, panel: String) {
        for _ in 0..<12 {
            if element.exists && element.isHittable {
                let viewport = app.scrollViews[panel].frame.insetBy(dx: 0, dy: 8)
                let frame = element.frame
                if frame.midY >= viewport.minY && frame.midY <= viewport.maxY { return }
            }
            app.scrollViews[panel].scroll(byDeltaX: 0, deltaY: element.exists && element.frame.midY < app.scrollViews[panel].frame.minY ? 170 : -170)
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    func textExists(_ text: String, timeout: TimeInterval = 10) {
        let element = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
        if !element.exists { XCTAssertTrue(element.waitForExistence(timeout: timeout), text) }
    }
    func connectAI() {
        tab("AI"); edit(app.secureTextFields["OpenRouter API key"], "test-only-no-credits")
        app.buttons["Save to Keychain"].click()
    }
    func requestSuggestions(mode: String = "success") throws {
        try mode.write(to: root.appendingPathComponent("ai-mode"), atomically: true, encoding: .utf8)
        connectAI(); reveal(app.buttons["Generate suggestions"], panel: "ai.scroll"); app.buttons["Generate suggestions"].click()
    }
    func testAIProposalRequiresReviewAndHighlightIsUndoable() throws {
        launch(); try requestSuggestions()
        textExists("A strong team highlight.")
        XCTAssertEqual(try EditProject.read(from: projectURL).duration, 5)
        let apply = app.buttons["Keep this range"]; reveal(apply, panel: "ai.scroll"); apply.click()
        let result = try save(); XCTAssertEqual(result.duration, 2.5, accuracy: 0.001)
        app.typeKey("z", modifierFlags: .command); XCTAssertEqual(try save().duration, 5)
    }
    func testAICaptionEditsPersist() throws {
        launch(); try requestSuggestions(); textExists("A strong team highlight.")
        let apply = app.buttons["Apply caption edits"]; reveal(apply, panel: "ai.scroll"); apply.click()
        XCTAssertEqual(try save().captionTrack?.cues[0].text, "Push the castle together!")
    }
    func testAIAuthenticationErrorPreservesProject() throws {
        launch(); try requestSuggestions(mode: "auth"); textExists("API key")
        app.sheets.buttons["OK"].firstMatch.click(); XCTAssertEqual(try save().clips, project.clips)
        XCTAssertTrue(app.buttons["Generate suggestions"].isEnabled)
    }
    func testAIMalformedResponseShowsErrorAndAllowsRetry() throws {
        launch(); try requestSuggestions(mode: "invalid")
        XCTAssertTrue(app.sheets.buttons["OK"].firstMatch.waitForExistence(timeout: 10)); app.sheets.buttons["OK"].firstMatch.click()
        try "success".write(to: root.appendingPathComponent("ai-mode"), atomically: true, encoding: .utf8)
        app.buttons["Generate suggestions"].click(); textExists("A strong team highlight.")
    }
    func testAICancellationPreservesProject() throws {
        launch(); try requestSuggestions(mode: "slow")
        let cancel = app.buttons["Cancel"]; XCTAssertTrue(cancel.waitForExistence(timeout: 5)); if let panel = panelContaining(cancel) { reveal(cancel, panel: panel) }; cancel.click()
        waitEnabled(app.buttons["Generate suggestions"])
        XCTAssertFalse(app.buttons["Keep this range"].exists)
        XCTAssertEqual(try save().clips, project.clips)
    }
    func testCredentialRemovalDisablesAssistant() throws {
        launch(); connectAI(); toggleDisclosure("OpenRouter · connected"); app.buttons["Remove"].click()
        XCTAssertFalse(app.buttons["Generate suggestions"].isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("test-credential").path))
    }
    func testGeneratedImageCanBeImportedIntoTimeline() throws {
        launch(); connectAI(); toggleDisclosure("Generate images & video")
        app.buttons["Load available models"].click()
        let prompt = app.textViews["generation.prompt"]; XCTAssertTrue(prompt.waitForExistence(timeout: 10)); edit(prompt, "A castle victory screen")
        let generate = app.buttons["Generate image"]; reveal(generate, panel: "ai.scroll"); generate.click()
        let add = app.buttons["Add to library"]; XCTAssertTrue(add.waitForExistence(timeout: 15)); reveal(add, panel: "ai.scroll"); add.click()
        assertLabel("editor.status", "Imported 1 recording. Add one to your timeline.", timeout: 20)
        let result = try save(); XCTAssertEqual(result.media.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.media.last!.url.path))
        tab("Media")
        let append = app.buttons["media.add.\(result.media.last!.id)"]
        reveal(append, panel: "media.scroll")
        append.click(); assertLabel("timeline.count", "2 clips"); XCTAssertEqual(try save().duration, 10, accuracy: 0.1)
    }
    func testVideoGenerationFailureIsRecordedWithoutAddingMedia() throws {
        launch(); connectAI(); toggleDisclosure("Generate images & video")
        app.radioButtons["Video"].click()
        let prompt = app.textViews["generation.prompt"]; XCTAssertTrue(prompt.waitForExistence(timeout: 10)); edit(prompt, "A castle flyover")
        let generate = app.buttons["Generate video"]; reveal(generate, panel: "ai.scroll"); generate.click()
        XCTAssertTrue(app.sheets.buttons["OK"].firstMatch.waitForExistence(timeout: 15)); app.sheets.buttons["OK"].firstMatch.click()
        textExists("Video · failed"); XCTAssertEqual(try save().media.count, 2)
        let metadata = root.appendingPathComponent("Generated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }
    func installSpeechFixture(mode: String = "success") throws {
        let helpers = root.appendingPathComponent("Helpers"), models = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("test model boundary".utf8).write(to: models.appendingPathComponent("ggml-base.bin"))
        try mode.write(to: root.appendingPathComponent("whisper-mode"), atomically: true, encoding: .utf8)
        let executable = helpers.appendingPathComponent("whisper-cli")
        let bundled = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Helpers/whisper-cli").absoluteURL
        // Keep executable fixture code in the build-time resources outside generated test data.
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: bundled)

    }
    func testLocalCaptionsUseSelectedOBSAudioTrack() throws {
        try installSpeechFixture(); launch(); tab("Captions")
        app.popUpButtons["captions.audio-track"].click(); app.menuItems["Audio 2"].click()
        waitEnabled(app.buttons["captions.generate"]); tapInPanel(app.buttons["captions.generate"])
        assertLabel("editor.status", "Created 1 captions locally. Review the wording and timing.", timeout: 15)
        let result = try save(); XCTAssertEqual(result.transcripts?.last?.audioTrack, 1)
        XCTAssertEqual(result.captionTrack?.cues.first?.text, "Local microphone caption.")
    }
    func testLocalTranscriptionFailurePreservesExistingCaptions() throws {
        try installSpeechFixture(mode: "failure"); launch(); tab("Captions"); waitEnabled(app.buttons["captions.generate"]); tapInPanel(app.buttons["captions.generate"])
        textExists("Fixture speech engine failure"); app.sheets.buttons["OK"].firstMatch.click()
        XCTAssertEqual(try save().captionTrack, project.captionTrack); XCTAssertTrue(app.buttons["captions.generate"].isEnabled)
    }
    func testLocalTranscriptionCancellationPreservesExistingCaptions() throws {
        try installSpeechFixture(mode: "slow"); launch(); tab("Captions"); waitEnabled(app.buttons["captions.generate"]); tapInPanel(app.buttons["captions.generate"])
        let cancel = app.buttons["Cancel transcription"]; XCTAssertTrue(cancel.waitForExistence(timeout: 5)); if let panel = panelContaining(cancel) { reveal(cancel, panel: panel) }; cancel.click()
        waitEnabled(app.buttons["captions.generate"]); XCTAssertEqual(try save().captionTrack, project.captionTrack)
    }
    func testCaptionAppearancePersists() throws {
        launch(); tab("Captions"); toggleDisclosure("Caption appearance")
        tapInPanel(app.checkBoxes["Uppercase"]); tapInPanel(app.checkBoxes["Background box"]); tapInPanel(app.checkBoxes["Burn captions into video"])
        let result = try save(); XCTAssertEqual(result.captionTrack?.style.uppercase, true); XCTAssertEqual(result.captionTrack?.style.background, false); XCTAssertFalse(result.options.burnCaptions)
    }
    func testOverlayAddEditRemoveAndUndo() throws {
        launch(); tab("Layers"); app.popUpButtons["overlay.source"].click(); app.menuItems["facecam"].click()
        app.buttons["Add video overlay at playhead"].click(); toggleDisclosure("facecam")
        edit(app.textFields["Duration"], "2"); let apply = app.buttons["Apply"]; reveal(apply, panel: "layers.scroll"); apply.click()
        XCTAssertEqual(try save().overlays?.first?.duration, 2)
        app.buttons["Remove"].click(); XCTAssertEqual(try save().overlays?.count, 0)
        app.typeKey("z", modifierFlags: .command); XCTAssertEqual(try save().overlays?.count, 1)
    }
    func testAudioImportFadeEditAndRemove() throws {
        launch(); tab("Layers"); app.buttons["Add music / audio…"].click(); chooseFile(fixture.appendingPathComponent("music.m4a"))
        let audio = app.disclosureTriangles["music"]; XCTAssertTrue(audio.waitForExistence(timeout: 10)); toggleDisclosure(audio.label)
        edit(app.textFields["Fade in"], "0.5"); edit(app.textFields["Fade out"], "0.7")
        let apply = app.buttons["Apply"]; reveal(apply, panel: "layers.scroll"); apply.click()
        let result = try save(); XCTAssertEqual(result.music?.first?.fadeIn, 0.5); XCTAssertEqual(result.music?.first?.fadeOut, 0.7)
        app.buttons["Remove"].click(); XCTAssertEqual(try save().music?.count, 0)
    }
    func testColorPresetSpeedAndTransformKeyframes() throws {
        launch(); let color = app.disclosureTriangles["Color adjustments"]; reveal(color, panel: "inspector.scroll"); toggleDisclosure(color.label)
        let blackWhite = app.buttons["B&W"]; reveal(blackWhite, panel: "inspector.scroll"); blackWhite.click()
        XCTAssertEqual(try save().clips[0].adjustments?.saturation, 0)
        toggleDisclosure(color.label)
        let speed = app.disclosureTriangles["Speed & fades"]; toggleDisclosure(speed.label); tapInPanel(app.popUpButtons["adjust.speed"]); app.menuItems["2×"].click()
        let apply = app.buttons["Apply adjustments"]; reveal(apply, panel: "inspector.scroll"); apply.click()
        XCTAssertEqual(try save().duration, 2.5, accuracy: 0.01); toggleDisclosure(speed.label)
        let transform = app.disclosureTriangles["Transform & crop"]; toggleDisclosure(transform.label); tapInPanel(app.checkBoxes["Mirror"])
        let keyframe = app.buttons["Add keyframe at playhead"]; reveal(keyframe, panel: "inspector.scroll"); keyframe.click()
        let result = try save(); XCTAssertEqual(result.clips[0].adjustments?.mirror, true); XCTAssertEqual(result.clips[0].adjustments?.keyframes?.count, 1)
    }
    func testNewProjectCancelAndDiscardProtectEdits() throws {
        launch(); app.buttons["canvas.square"].click(); app.typeKey("n", modifierFlags: .command)
        let cancel = app.dialogs.buttons["Cancel"].firstMatch; XCTAssertTrue(cancel.waitForExistence(timeout: 5)); if let panel = panelContaining(cancel) { reveal(cancel, panel: panel) }; cancel.click()
        assertLabel("timeline.count", "1 clips")
        app.typeKey("n", modifierFlags: .command); app.dialogs.buttons["Discard"].firstMatch.click()
        assertLabel("project.name", "Untitled project"); XCTAssertFalse(app.buttons["project.export"].isEnabled)
    }
    func testRecoverAutosaveFromMenu() throws {
        let recovery = root.appendingPathComponent("Recovery/autosave.cutline")
        try FileManager.default.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
        project.name = "Recovered stream"; try project.write(to: recovery)
        launch(project: false); menu("File", "Recover Autosave"); assertLabel("project.name", "Recovered stream"); waitEnabled(app.buttons["project.export"])
        assertLabel("timeline.count", "1 clips")
    }
    func testCommandLineProjectLaunch() {
        app.launchArguments = ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES", "--project", projectURL.path]
        app.launch(); app.activate()
        assertLabel("project.name", "UI test project"); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime-ready").path)); waitEnabled(app.buttons["project.export"])
        assertLabel("timeline.count", "1 clips")
    }
    func testPlaybackAdvancesAndPauses() {
        launch(); app.buttons["player.play"].click()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != '00:00.00'"), object: app.staticTexts["player.time"])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        app.buttons["player.play"].click()
        let paused = app.staticTexts["player.time"].value as? String
        app.typeKey("s", modifierFlags: .command); assertLabel("editor.status", "Project saved.")
        XCTAssertEqual(app.staticTexts["player.time"].value as? String, paused)
    }
}
