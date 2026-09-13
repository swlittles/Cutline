import XCTest
import CutlineCore

@MainActor final class EditorUITests: XCTestCase {
    var app: XCUIApplication!
    var root: URL!
    var project: EditProject!
    var projectURL: URL!
    var fixture: URL { Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures").absoluteURL }
    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        project = EditProject(); project.name = "UI test project"
        let media = MediaItem(url: fixture.appendingPathComponent("gameplay.mp4"), duration: 5)
        let facecam = MediaItem(url: fixture.appendingPathComponent("facecam.mp4"), duration: 3)
        project.media = [media,facecam]; project.clips = [TimelineClip(mediaID: media.id, sourceOut: 5)]
        project.options.resolution = 720
        project.generateCaptions(from: SourceTranscript(mediaID: media.id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 0.2, end: 1.2, text: "Push the castle!"), TranscriptSegment(start: 3, end: 4, text: "We won the match!")]))
        projectURL = root.appendingPathComponent("UI test project.cutline"); try project.write(to: projectURL)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("artwork.png"), to: root.appendingPathComponent("artwork.png"))
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("gameplay.mp4"), to: root.appendingPathComponent("gameplay.mp4"))
        app = XCUIApplication(); app.launchEnvironment["CUTLINE_TEST_ROOT"] = root.path
    }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
            let tree = XCTAttachment(string: app.windows.allElementsBoundByIndex.map { $0.debugDescription }.joined(separator: "\n")); tree.lifetime = .keepAlways; add(tree)
        }
        app.terminate()
        try? FileManager.default.removeItem(at: root)
    }
    func launch(project loaded: Bool = true, select: Bool = true) {
        app.launchArguments = ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"] + (loaded ? ["--project", projectURL.path] : [])
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["media.import"].waitForExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime-ready").path), "UI tests require the isolated Debug runtime")
        app.staticTexts["project.name"].click()
        if loaded { waitEnabled(app.buttons["project.export"]); assertLabel("timeline.count", "\(project.clips.count) clips"); if select { selectClip() } }
    }
    func selectClip() { app.descendants(matching: .any)["clip.\(project.clips[0].id)"].firstMatch.click() }
    func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 15) {
        if !element.exists { XCTAssertTrue(element.waitForExistence(timeout: timeout)) }
        if element.isEnabled { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    func assertLabel(_ id: String, _ text: String, timeout: TimeInterval = 10) {
        let element = app.staticTexts[id]
        if element.exists && ((element.value as? String) == text || element.label == text) { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR label == %@", text, text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Expected \(id) = \(text), got \(element.value ?? element.label)")
    }
    func edit(_ field: XCUIElement, _ value: String, submit: Bool = false) {
        if !field.exists { XCTAssertTrue(field.waitForExistence(timeout: 5)) }
        if let panel = panelContaining(field) { reveal(field, panel: panel) }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        if value.isEmpty { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        else { field.typeText(value) }
        if submit { field.typeKey(.return, modifierFlags: []) }
    }
    func tab(_ name: String) { app.radioButtons[name].click() }
    func save() throws -> EditProject {
        app.typeKey("s", modifierFlags: .command)
        assertLabel("editor.status", "Project saved.")
        return try EditProject.read(from: projectURL)
    }
    func menu(_ name: String, _ item: String) { app.menuBars.menuBarItems[name].click(); app.menuItems[item].click() }
    func chooseFile(_ url: URL) {
        let open = app.buttons["OKButton"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command,.shift])
        let field = app.textFields["PathTextField"]
        edit(field, url.path)
        app.typeKey(.return, modifierFlags: [])
        waitEnabled(open); open.click()
    }
    func saveDialog(to url: URL) {
        XCTAssertTrue(app.textFields["saveAsNameTextField"].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command,.shift])
        edit(app.textFields["PathTextField"], url.deletingLastPathComponent().path)
        app.typeKey(.return, modifierFlags: [])
        edit(app.textFields["saveAsNameTextField"], url.lastPathComponent)
        app.dialogs.buttons["Save"].firstMatch.click()
    }
    func testLaunchAndWorkspaceNavigation() {
        launch(project: false)
        XCTAssertFalse(app.buttons["project.export"].isEnabled)
        tab("Captions"); XCTAssertFalse(app.buttons["captions.generate"].isEnabled)
        tab("AI"); XCTAssertFalse(app.buttons["Generate suggestions"].isEnabled)
        tab("Layers"); XCTAssertFalse(app.buttons["Add video overlay at playhead"].isEnabled)
    }
    func testImportThroughNativeDialogAndAppend() throws {
        launch(project: false); app.buttons["media.import"].click(); chooseFile(fixture.appendingPathComponent("gameplay.mp4"))
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'media.add.'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.click(); assertLabel("timeline.count", "1 clips"); waitEnabled(app.buttons["project.export"])
    }
    func testNativeOpenAndSaveAs() throws {
        launch(project: false); app.typeKey("o", modifierFlags: .command); chooseFile(projectURL)
        assertLabel("project.name", "UI test project"); waitEnabled(app.buttons["project.export"])
        app.typeKey("s", modifierFlags: [.command,.shift])
        saveDialog(to: root.appendingPathComponent("Saved copy.cutline")); assertLabel("project.name", "Saved copy")
        XCTAssertEqual(try EditProject.read(from: root.appendingPathComponent("Saved copy.cutline")).captionTrack?.cues.count, 2)
    }
    func testSplitDuplicateDeleteUndoRedo() throws {
        launch(); app.descendants(matching: .any)["clip.\(project.clips[0].id)"].firstMatch.click()
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: .option)
        app.typeKey("b", modifierFlags: .command)
        // A split closer than 100 ms to an edge is rejected.
        assertLabel("timeline.count", "1 clips")
        app.typeKey(.leftArrow, modifierFlags: [])
        for _ in 0..<15 { app.typeKey(.rightArrow, modifierFlags: .option) }
        app.typeKey("b", modifierFlags: .command); assertLabel("timeline.count", "2 clips")
        app.typeKey("d", modifierFlags: .command); assertLabel("timeline.count", "3 clips")
        app.typeKey(.delete, modifierFlags: []); assertLabel("timeline.count", "2 clips")
        app.typeKey("z", modifierFlags: .command); assertLabel("timeline.count", "3 clips")
        app.typeKey("z", modifierFlags: [.command,.shift]); assertLabel("timeline.count", "2 clips")
        let result = try save(); XCTAssertEqual(result.clips.count, 2); XCTAssertEqual(result.duration, 5, accuracy: 0.05)
    }
    func testTrimAndMutePersist() throws {
        launch(); app.descendants(matching: .any)["clip.\(project.clips[0].id)"].firstMatch.click()
        edit(app.textFields["trim.In"], "1", submit: true)
        edit(app.textFields["trim.Out"], "4", submit: true)
        let mute = app.buttons["clip.mute"]; reveal(mute, panel: "inspector.scroll"); mute.click()
        let result = try save(); XCTAssertEqual(result.clips[0].sourceIn, 1); XCTAssertEqual(result.clips[0].sourceOut, 4); XCTAssertEqual(result.clips[0].volume, 0)
    }
    func testCanvasResolutionAndFrameRatePersist() throws {
        launch(); app.buttons["canvas.portrait"].click()
        app.popUpButtons["export.quality"].click(); app.menuItems["1080p"].click()
        app.popUpButtons["export.fps"].click(); app.menuItems["60"].click()
        let result = try save(); XCTAssertEqual(result.format, .portrait); XCTAssertEqual(result.options.fps, 60); XCTAssertEqual(result.options.resolution, 1080)
    }
    func testCaptionTextSearchEditAndDelete() throws {
        launch(); tab("Captions")
        assertLabel("captions.count", "2 CAPTIONS")
        reveal(app.textFields["Search the transcript"], panel: "captions.scroll"); edit(app.textFields["Search the transcript"], "castle"); assertLabel("captions.count", "1 CAPTIONS")
        let id = project.captionTrack!.cues[0].id
        reveal(app.descendants(matching: .any)["caption.text.\(id)"].firstMatch, panel: "captions.scroll"); edit(app.descendants(matching: .any)["caption.text.\(id)"].firstMatch, "Push together!")
        waitEnabled(app.buttons["caption.apply.\(id)"]); tapInPanel(app.buttons["caption.apply.\(id)"]); assertLabel("captions.count", "0 CAPTIONS")
        edit(app.textFields["Search the transcript"], "")
        XCTAssertEqual(app.textFields["Search the transcript"].value as? String, "")
        assertLabel("captions.count", "2 CAPTIONS")
        assertLabel("timeline.count", "1 clips")
        XCTAssertEqual(try save().captionTrack!.cues[0].text, "Push together!")
        tapInPanel(app.buttons["caption.delete.\(id)"]); assertLabel("captions.count", "1 CAPTIONS")
        app.typeKey("z", modifierFlags: .command); assertLabel("captions.count", "2 CAPTIONS")
    }
    func testCaptionCutAndUndo() throws {
        launch(); tab("Captions"); reveal(app.buttons["Cut this range from video"].firstMatch, panel: "captions.scroll"); app.buttons["Cut this range from video"].firstMatch.click()
        assertLabel("timeline.count", "2 clips"); assertLabel("captions.count", "1 CAPTIONS")
        XCTAssertEqual(try save().duration, 4, accuracy: 0.001)
        app.typeKey("z", modifierFlags: .command); assertLabel("timeline.count", "1 clips"); assertLabel("captions.count", "2 CAPTIONS")
    }
    func testSpeechGapReviewAndCut() throws {
        launch(); tab("Captions"); toggleDisclosure("Edit video through the transcript")
        reveal(app.buttons["Find gaps"], panel: "captions.scroll"); app.buttons["Find gaps"].click(); let cut = app.buttons["Cut selected gaps"]; waitEnabled(cut); cut.click()
        let result = try save(); XCTAssertEqual(result.duration, 3.6, accuracy: 0.001); XCTAssertEqual(result.projectedCaptions().count, 2)
    }
    func testMissingMediaShowsActionableError() throws {
        project.media[0].url = root.appendingPathComponent("gone.mp4"); try project.write(to: projectURL)
        launch(project: false); app.typeKey("o", modifierFlags: .command); chooseFile(projectURL)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'source file is missing' OR label CONTAINS 'source file is missing'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["project.export"].isEnabled)
        app.sheets.buttons["OK"].firstMatch.click()
    }
    func testExportFromNativeDialogProducesRealVideo() async throws {
        launch(); app.buttons["project.export"].click()
        let output = root.appendingPathComponent("UI export.mp4")
        saveDialog(to: output)
        assertLabel("editor.status", "Export complete: UI export.mp4", timeout: 30)
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 1000)
        let media = try await CompositionEngine.inspect(output)
        XCTAssertEqual(media.duration, 5, accuracy: 0.1)
        XCTAssertGreaterThan(media.audioTrackCount ?? 0, 0)
    }
}

private extension XCUIElement {
    func scrollToVisibleIfNeeded(in app: XCUIApplication) {
        for _ in 0..<8 { if isHittable { return }; app.scrollViews["inspector.scroll"].scroll(byDeltaX: 0, deltaY: -180) }
    }
}
