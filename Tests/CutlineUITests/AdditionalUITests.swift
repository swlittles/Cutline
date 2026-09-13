import XCTest
import CutlineCore

extension EditorUITests {
    func testNativeSubtitleImportAndBothExportFormats() throws {
        project.captionTrack = nil; try project.write(to: projectURL)
        launch(); tab("Captions")
        let importButton = app.buttons["Import…"]; reveal(importButton, panel: "captions.scroll"); importButton.click()
        chooseFile(fixture.appendingPathComponent("captions.srt")); XCTAssertEqual(try save().projectedCaptions().map(\.text), ["Push the castle!", "We won the match!"])
        for (item, ext) in [("SubRip (.srt)","srt"),("WebVTT (.vtt)","vtt")] {
            let export = app.descendants(matching: .any)["captions.export"].firstMatch; reveal(export, panel: "captions.scroll"); export.click(); app.menuItems[item].click()
            let output = root.appendingPathComponent("Captions.\(ext)"); saveDialog(to: output)
            assertLabel("editor.status", "Subtitles exported.")
            let cues = try SubtitleFile.decode(String(contentsOf: output, encoding: .utf8))
            XCTAssertEqual(cues.map(\.text), ["Push the castle!", "We won the match!"])
        }
    }
    func testLocalVoiceoverCreatesPlayableAudioLayer() throws {
        launch(); tab("Layers"); toggleDisclosure("Local text to speech")
        let text = app.descendants(matching: .any)["voiceover.text"].firstMatch; reveal(text, panel: "layers.scroll"); edit(text, "We won the game.")
        let generate = app.buttons["Generate voiceover"]; reveal(generate, panel: "layers.scroll"); generate.click()
        // Wait for a generated voiceover to appear in the layer controls.
        let generated = app.disclosureTriangles.matching(NSPredicate(format: "label MATCHES '[A-Fa-f0-9-]{36}'")).firstMatch
        XCTAssertTrue(generated.waitForExistence(timeout: 20))
        let result = try save(); XCTAssertEqual(result.music?.count, 1)
        XCTAssertGreaterThan(result.music!.first!.duration, 0)
        XCTAssertGreaterThan(try Data(contentsOf: result.music!.first!.url).count, 1000)
    }
    func testHighlightMarkerShortcutAndRemoval() throws {
        launch(); app.typeKey("m", modifierFlags: [.command,.shift]); tab("Layers")
        let result = try save(); XCTAssertEqual(result.markers?.count, 1)
        app.typeKey("z", modifierFlags: .command); XCTAssertEqual(try save().markers?.count ?? 0, 0)
    }
    func testInvalidCaptionTimingShowsErrorWithoutSavingBadEdit() throws {
        launch(); tab("Captions")
        let start = app.textFields["Start"].firstMatch; reveal(start, panel: "captions.scroll"); edit(start, "99")
        let apply = app.buttons["caption.apply.\(project.captionTrack!.cues[0].id)"]; tapInPanel(apply)
        textExists("Enter valid caption text and timing")
        app.sheets.buttons["OK"].firstMatch.click()
        XCTAssertEqual(try save().captionTrack, project.captionTrack)
    }
    func testModelDownloadFailureKeepsCaptionActionDisabled() throws {
        launch(); tab("Captions"); app.buttons["Download speech model"].click()
        textExists("Model download failed")
        app.sheets.buttons["OK"].firstMatch.click()
        XCTAssertFalse(app.buttons["captions.generate"].isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/ggml-base.bin").path))
    }
    func testIndependentOBSTrackGainPersists() throws {
        launch(); let tracks = app.disclosureTriangles["Source audio tracks (2)"]; reveal(tracks, panel: "inspector.scroll"); toggleDisclosure(tracks.label)
        let gain = app.sliders["audio.gain.0"]; reveal(gain, panel: "inspector.scroll")
        // Drag beyond the endpoint: normalized slider adjustment is approximate on macOS 15.
        gain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(forDuration: 0.2, thenDragTo: gain.coordinate(withNormalizedOffset: CGVector(dx: -0.1, dy: 0.5)))
        let apply = app.buttons["Apply adjustments"]; reveal(apply, panel: "inspector.scroll"); apply.click()
        let result = try save(); XCTAssertEqual(result.clips[0].adjustments?.audioGains["0"], 0)
        XCTAssertEqual(result.clips[0].adjustments?.audioGains["1"] ?? 1, 1)
    }
}

extension EditorUITests {
    func testDragReordersTimelineClipsAndUndoRestoresOrder() throws {
        let second = TimelineClip(mediaID: project.media[1].id, sourceOut: 3)
        project.clips.append(second); try project.write(to: projectURL)
        launch()
        let firstElement = app.descendants(matching: .any)["clip.\(project.clips[0].id)"].firstMatch
        let secondElement = app.descendants(matching: .any)["clip.\(second.id)"].firstMatch
        secondElement.click(forDuration: 0.3, thenDragTo: firstElement)
        XCTAssertEqual(try save().clips.map(\.id), [second.id, project.clips[0].id])
        app.typeKey("z", modifierFlags: .command); XCTAssertEqual(try save().clips, project.clips)
    }
    func testDraggingTrimHandleChangesSourceRange() throws {
        launch()
        let clip = app.descendants(matching: .any)["clip.\(project.clips[0].id)"].firstMatch
        let edge = clip.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.5))
        let target = clip.coordinate(withNormalizedOffset: CGVector(dx: 0.797, dy: 0.5))
        edge.click(forDuration: 0.2, thenDragTo: target)
        let result = try save(); XCTAssertEqual(result.clips[0].sourceOut, 4, accuracy: 0.05)
        XCTAssertEqual(result.clips[0].sourceIn, 0)
    }
    func testRelinkRejectsShorterSourceThenAcceptsValidRecording() throws {
        launch()
        let media = app.descendants(matching: .any)["media.item.\(project.media[0].id)"].firstMatch
        XCTAssertTrue(media.exists)
        media.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).rightClick(); app.menuItems["Relink source…"].click(); chooseFile(fixture.appendingPathComponent("facecam.mp4"))
        textExists("replacement is shorter"); app.sheets.buttons["OK"].firstMatch.click()
        XCTAssertEqual(try save().media[0].url, project.media[0].url)
        let replacement = root.appendingPathComponent("Relinked source.mp4")
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("gameplay.mp4"), to: replacement)
        media.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).rightClick(); app.menuItems["Relink source…"].click(); chooseFile(replacement)
        assertLabel("editor.status", "Relinked gameplay."); waitEnabled(app.buttons["project.export"])
        let result = try save(); XCTAssertEqual(result.media[0].url, replacement); XCTAssertEqual(result.media[0].id, project.media[0].id)
    }
}

extension EditorUITests {
    func testCancelLongExportRemovesPartialOutputAndKeepsProject() throws {
        project.clips = (0..<60).map { _ in TimelineClip(mediaID: project.media[0].id, sourceOut: 5) }
        project.captionTrack = nil; project.options.resolution = 2160; project.options.fps = 60
        try project.write(to: projectURL); launch(select: false)
        let output = root.appendingPathComponent("Cancelled export.mp4")
        app.buttons["project.export"].click(); saveDialog(to: output)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.click()
        assertLabel("editor.status", "Export cancelled.", timeout: 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".cutline-") })
        XCTAssertEqual(try EditProject.read(from: projectURL).duration, 300)
        waitEnabled(app.buttons["project.export"])
    }
}

extension EditorUITests {
    func testStoppedVideoJobResumesDownloadsAndImportsWithoutResubmission() throws {
        try "video-pending".write(to: root.appendingPathComponent("ai-mode"), atomically: true, encoding: .utf8)
        launch(); connectAI(); toggleDisclosure("Generate images & video")
        app.radioButtons["Video"].click()
        let prompt = app.textViews["generation.prompt"]; XCTAssertTrue(prompt.waitForExistence(timeout: 10)); edit(prompt, "A victory intro")
        let generate = app.buttons["Generate video"]; reveal(generate, panel: "ai.scroll"); generate.click()
        let stop = app.buttons["Stop waiting"]; XCTAssertTrue(stop.waitForExistence(timeout: 10)); tapInPanel(stop)
        let resume = app.buttons["Resume job"]; waitEnabled(resume)
        try "video-complete".write(to: root.appendingPathComponent("ai-mode"), atomically: true, encoding: .utf8)
        tapInPanel(resume)
        let add = app.buttons["Add to library"]; XCTAssertTrue(add.waitForExistence(timeout: 15)); tapInPanel(add)
        assertLabel("editor.status", "Imported 1 recording. Add one to your timeline.")
        let result = try save(); XCTAssertEqual(result.media.count, 3); XCTAssertEqual(result.media.last?.duration ?? 0, 5, accuracy: 0.1)
        let requests = try String(contentsOf: root.appendingPathComponent("request-log"), encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(requests.filter { $0 == "POST /api/v1/videos" }.count, 1)
        XCTAssertEqual(requests.filter { $0 == "GET /api/v1/videos/job_ui_test/content" }.count, 1)
    }
}
