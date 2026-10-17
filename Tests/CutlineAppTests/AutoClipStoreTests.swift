import XCTest
import CutlineCore
@testable import Cutline

extension EditorStoreTests {
    /// A confirmed, branded recording whose Track 1 carries the fixture's audio burst.
    func clipSeed(roles: [AudioRole] = [.mic, .ignore]) -> MediaItem {
        try! store.saveCreatorProfile(ShortBranding(text: "example.test/player"))
        var media = MediaItem(url: fixture.appendingPathComponent("autoclip.mp4"), duration: 12)
        media.audioTrackCount = 2; media.audioRoles = roles
        media.shortFraming = ShortFraming(); media.shortFraming?.confirmed = true
        store.project.media = [media]; store.project.clips = []; store.project.options.resolution = 720
        store.clipSettings.lead = 1; store.clipSettings.tail = 1
        return media
    }
    func findMoments(roles: [AudioRole] = [.mic, .ignore]) async throws -> MediaItem {
        let media = clipSeed(roles: roles)
        store.mode = .clipper; store.chooseVOD(media.id)
        try await until({ !self.store.isScanningClips && self.store.clipReport != nil }, timeout: 30)
        return media
    }
    func testChoosingRecordingStartsBackgroundMeasurementWithoutTimeline() async throws {
        let media = clipSeed()
        store.chooseVOD(media.id)
        XCTAssertTrue(store.isScanningClips, "Measuring starts as soon as a recording is chosen")
        XCTAssertEqual(store.project.clipReview?.mediaID, media.id)
        try await until({ !self.store.isScanningClips }, timeout: 30)
        XCTAssertNil(store.error); XCTAssertEqual(store.moments.count, 1)
        XCTAssertEqual(store.clipAnalysis?.audioTracks?.count, 2)
        XCTAssertTrue(store.project.clips.isEmpty); XCTAssertNil(store.project.transcripts)
        XCTAssertEqual(store.focusedMoment, store.moments.first?.id)
        XCTAssertEqual(store.clipMessage, "Found 1 moment to review.")
    }
    func testRolesDriveDetectionAndSensitivityReevaluatesWithoutRescan() async throws {
        _ = try await findMoments()
        let measured = store.clipAnalysis
        XCTAssertEqual(store.clipSettings.audioTrack, 0); XCTAssertEqual(store.clipSettings.exportTracks, [0])
        store.clipSettings.visionEnabled = false
        store.commit { $0.media[0].audioRoles = [.mix, .mic] }; store.adoptRoutes()
        XCTAssertEqual(store.clipSettings.audioTrack, 1, "Detection prefers the mic track")
        try await until({ self.store.clipReport?.settings.audioTrack == 1 }, timeout: 10)
        XCTAssertTrue(store.moments.isEmpty, "Track 2 is quiet")
        XCTAssertFalse(store.isScanningClips); XCTAssertEqual(store.clipAnalysis, measured, "No new measurement was needed")
        store.commit { $0.media[0].audioRoles = [.mic, .ignore] }; store.adoptRoutes()
        store.clipSettings.sensitivity = 1
        try await until({ self.store.clipReport?.settings.audioTrack == 0 && self.store.moments.count == 1 }, timeout: 10)
    }
    func testCachedMeasurementsMakeReopeningInstant() async throws {
        let media = try await findMoments()
        try await until({ FileManager.default.fileExists(atPath: self.root.appendingPathComponent("Analysis").path) }, timeout: 10)
        store.resetJobs(); XCTAssertNil(store.clipAnalysis)
        store.chooseVOD(media.id)
        XCTAssertNotNil(store.clipAnalysis?.visual, "Loaded from the on-disk cache")
        XCTAssertFalse(store.isScanningClips)
        try await until({ self.store.moments.count == 1 }, timeout: 5)
    }
    func testRegionChangeRestartsOnlyVisualSampling() async throws {
        _ = try await findMoments()
        let audio = store.clipAnalysis?.audioTracks
        store.clipSettings.motionRegion.x = 0.1
        try await until({ self.store.isScanningClips }, timeout: 5)
        try await until({ !self.store.isScanningClips && self.store.clipAnalysis?.visual?.motionRegion.x == 0.1 }, timeout: 30)
        XCTAssertEqual(store.clipAnalysis?.audioTracks, audio)
    }
    func testInvalidSettingsReportOnlyWhenExplicit() {
        let media = clipSeed(); store.clipMediaID = media.id
        store.clipSettings.audioRiseDB = .nan
        store.beginAnalysis(); XCTAssertNil(store.error); XCTAssertFalse(store.isScanningClips)
        store.scanAutoClips(); XCTAssertNotNil(store.error); XCTAssertFalse(store.isScanningClips)
    }
    func testScanCancellationAndResetDiscardResults() async throws {
        let media = clipSeed(); store.chooseVOD(media.id); store.clipTask?.cancel()
        try await until { !self.store.isScanningClips }
        XCTAssertNil(store.clipReport); XCTAssertEqual(store.clipMessage, "Scan cancelled.")
        store.scanAutoClips(); store.resetJobs()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.clipReport); XCTAssertFalse(store.isScanningClips); XCTAssertNil(store.clipAnalysis)
    }
    func testGameProfilesRetainPerGameEditsButKeepTracks() {
        store.clipSettings.audioTrack = 1
        store.selectClipGame(.valorant); store.clipSettings.aliases = "Custom player"
        store.selectClipGame(.cs2); XCTAssertEqual(store.clipSettings.aliases, ""); XCTAssertEqual(store.clipSettings.audioTrack, 1)
        store.selectClipGame(.valorant); XCTAssertEqual(store.clipSettings.aliases, "Custom player")
    }
    func testCalibrationClearsOnSourceProfileAndProjectChanges() {
        store.clipSettings.hudCalibrated = true; store.clipMediaID = UUID(); XCTAssertFalse(store.clipSettings.hudCalibrated)
        store.clipSettings.hudCalibrated = true; store.selectClipGame(.valorant); XCTAssertFalse(store.clipSettings.hudCalibrated)
        store.clipSettings.hudCalibrated = true; store.resetJobs(); XCTAssertFalse(store.clipSettings.hudCalibrated)
    }
}

extension EditorStoreTests {
    func testStepGatesFollowSetupMomentsAndDecisions() async throws {
        XCTAssertFalse(store.canEnter(.setup))
        var media = clipSeed(); media.shortFraming?.confirmed = false; store.project.media = [media]
        store.chooseVOD(media.id)
        XCTAssertTrue(store.canEnter(.setup)); XCTAssertFalse(store.canEnter(.review))
        store.goTo(.review); XCTAssertEqual(store.clipStep, .importVOD, "Locked steps cannot be entered")
        XCTAssertTrue(store.completeSetup(framing: ShortFraming(), roles: [.mic, .ignore], game: .valorant, branding: nil, presetName: nil))
        XCTAssertEqual(store.clipStep, .review, "Setup goes straight to picking clips while moments are found")
        XCTAssertEqual(store.project.media[0].shortFraming?.confirmed, true)
        XCTAssertEqual(store.project.media[0].audioRoles, [.mic, .ignore]); XCTAssertEqual(store.clipSettings.game, .valorant)
        try await until({ !self.store.isScanningClips && !self.store.moments.isEmpty }, timeout: 30)
        XCTAssertFalse(store.canEnter(.export))
        store.goTo(.review); store.setHook(store.focusedMoment!, "Clean"); XCTAssertTrue(store.keepFocused())
        XCTAssertTrue(store.canEnter(.export))
    }
    func testSetupRequiresBrandingAndSavesScenePreset() throws {
        var media = MediaItem(url: fixture.appendingPathComponent("autoclip.mp4"), duration: 12); media.audioTrackCount = 2
        store.project.media = [media]; store.clipMediaID = media.id
        XCTAssertFalse(store.completeSetup(framing: ShortFraming(), roles: [.mix, .mic], game: .generic, branding: nil, presetName: nil))
        XCTAssertNotNil(store.error); store.error = nil
        var framing = ShortFraming(); framing.camera.x = 0.7
        XCTAssertTrue(store.completeSetup(framing: framing, roles: [.mix, .mic], game: .siege, branding: ShortBranding(text: "example.test/me"), presetName: "Siege cam"))
        XCTAssertEqual(store.creatorProfile.text, "example.test/me")
        XCTAssertEqual(try ScenePresetStore.load(from: root).map(\.name), ["Siege cam"])
        XCTAssertEqual(store.lastScenePreset?.framing.camera.x, 0.7)
        // Applying the preset to the next recording confirms its crops and roles in one step.
        var next = MediaItem(url: fixture.appendingPathComponent("gameplay.mp4"), duration: 5); next.audioTrackCount = 2
        store.project.media.append(next); store.clipMediaID = next.id
        store.applyScenePreset(store.lastScenePreset!)
        XCTAssertEqual(store.project.media[1].shortFraming?.confirmed, true); XCTAssertEqual(store.project.media[1].audioRoles, [.mix, .mic])
        XCTAssertEqual(store.clipSettings.game, .siege); XCTAssertTrue(store.canEnter(.review))
        store.undo(); XCTAssertNil(store.project.media[1].shortFraming)
    }
    func testKeepWithoutHookUsesSuggestionInOneUndoStep() async throws {
        _ = try await findMoments()
        let id = try XCTUnwrap(store.focusedMoment)
        let suggestion = store.suggestedHook(try XCTUnwrap(store.focusedCandidate))
        XCTAssertTrue(store.keepFocused(), "Keep never refuses")
        XCTAssertEqual(store.decision(id), .kept); XCTAssertEqual(store.autoClipHook(id), suggestion); XCTAssertEqual(store.exportProblems, [])
        store.undo(); XCTAssertEqual(store.decision(id), .undecided); XCTAssertEqual(store.autoClipHook(id), "", "Undo removes the decision and the suggested hook together")
        store.setHook(id, "Wait for it")
        XCTAssertTrue(store.keepFocused()); XCTAssertEqual(store.autoClipHook(id), "Wait for it", "A typed hook is never replaced")
        store.undo(); XCTAssertEqual(store.decision(id), .undecided)
        store.skipFocused(); XCTAssertEqual(store.decision(id), .skipped)
        store.clearFocusedDecision(); XCTAssertEqual(store.decision(id), .undecided)
    }
    func testTrimNudgesAreClampedAndFeedExport() async throws {
        _ = try await findMoments()
        let candidate = try XCTUnwrap(store.focusedCandidate)
        store.nudge(start: true, by: -1); store.nudge(start: false, by: 1)
        let shown = store.applied(candidate)
        XCTAssertEqual(shown.start, max(0, candidate.start - 1), accuracy: 0.001); XCTAssertEqual(shown.end, min(12, candidate.end + 1), accuracy: 0.001)
        store.setMomentRange(candidate.id, start: 5, end: 5.1)
        XCTAssertEqual(store.applied(candidate).end - store.applied(candidate).start, 1, accuracy: 0.001)
        store.setHook(candidate.id, "Trimmed")
        let project = try store.preparedAutoClip(candidate, report: store.clipReport!)
        XCTAssertEqual(project.clips[0].sourceIn, 5, accuracy: 0.001); XCTAssertEqual(project.shortHook, "Trimmed")
        store.resetMomentRange(candidate.id); XCTAssertEqual(store.applied(candidate), candidate)
    }
    func testManualMomentsBecomeCandidatesAndUndo() async throws {
        _ = try await findMoments()
        store.clipSettings.audioEnabled = false; store.clipSettings.visionEnabled = true; store.clipSettings.requireBoth = false
        store.clipSettings.sensitivity = 0
        store.addMoment(at: 11)
        try await until({ self.store.moments.contains { $0.evidence.contains { $0.detail.hasPrefix("Marked by you") } } }, timeout: 10)
        store.undo()
        try await until({ !self.store.moments.contains { $0.evidence.contains { $0.detail.hasPrefix("Marked by you") } } }, timeout: 10)
    }
    func testFocusAdvancesToNextUndecided() {
        let media = clipSeed(); store.clipMediaID = media.id
        store.project.clipReview = ClipReview(mediaID: media.id)
        let make = { (id: String, start: Double) in AutoClipCandidate(id: id, start: start, end: start + 2, score: 1, evidence: []) }
        store.clipReport = AutoClipReport(media: media, settings: store.clipSettings, candidates: [make("a", 0), make("b", 3), make("c", 6)], evidence: [])
        store.project.clipReview?.decide("b", .kept)
        store.focusedMoment = nil; store.ensureFocus(); XCTAssertEqual(store.focusedMoment, "a")
        store.skipFocused(); XCTAssertEqual(store.focusedMoment, "c", "Skips past already decided moments")
        store.moveFocus(-1); XCTAssertEqual(store.focusedMoment, "b")
        store.moveFocus(-5); XCTAssertEqual(store.focusedMoment, "a")
    }
    func testExportKeptClipsWritesOnlyKeptAndLeavesSessionUntouched() async throws {
        _ = try await findMoments()
        let id = try XCTUnwrap(store.focusedMoment)
        store.setHook(id, "Watch this play"); store.keepFocused()
        XCTAssertEqual(store.exportProblems, [])
        let before = store.project
        store.exportKeptClips(to: root)
        try await until({ !self.store.isExportingClips }, timeout: 40)
        XCTAssertNil(store.error); XCTAssertEqual(store.clipMessage, "Exported 1 clip.")
        let output = try XCTUnwrap(store.clipOutput)
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        XCTAssertEqual(files, ["01 - Watch this play.mp4", AutoClipBatch.projectsFolder])
        XCTAssertEqual(output.lastPathComponent, "autoclip shorts")
        XCTAssertEqual(store.project, before)
    }
    func testExportProblemsListMissingHooksAndBranding() async throws {
        _ = try await findMoments()
        let id = try XCTUnwrap(store.focusedMoment)
        store.project.clipReview?.decide(id, .kept)
        XCTAssertEqual(store.exportProblems, ["1 clip needs hook text."])
        try store.saveCreatorProfile(ShortBranding())
        XCTAssertTrue(store.exportProblems.contains("Add your channel name for the branding strip."))
        store.exportKeptClips(to: root)
        try await until { !self.store.isExportingClips }
        XCTAssertNotNil(store.error); XCTAssertNil(store.clipOutput)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(" shorts") || $0.hasPrefix(".cutline-clips") })
    }
    func testSavedSessionResumesInClipperAndEditsOpenInEditor() async throws {
        _ = try await findMoments()
        let id = try XCTUnwrap(store.focusedMoment)
        store.setHook(id, "Resume me"); store.keepFocused()
        let url = root.appendingPathComponent("session.cutline")
        try store.project.write(to: url)
        store.mode = .home; store.loadProject(url)
        XCTAssertEqual(store.mode, .clipper); XCTAssertEqual(store.clipStep, .review)
        try await until({ self.store.moments.count == 1 }, timeout: 30)
        store.savedProject = store.project
        store.openMomentInEditor(store.moments[0])
        XCTAssertEqual(store.mode, .editor); XCTAssertEqual(store.project.clips.count, 1); XCTAssertEqual(store.project.name, "Resume me")
        XCTAssertEqual(store.project.shortHook, "Resume me"); XCTAssertEqual(store.project.workflow, .mobileShort)
        // The session is parked, not discarded: returning restores every pick.
        XCTAssertNotNil(store.parkedSession); XCTAssertNotNil(store.continuableSessionName)
        store.returnToClips()
        XCTAssertEqual(store.mode, .clipper); XCTAssertNil(store.parkedSession)
        XCTAssertEqual(store.decision(id), .kept); XCTAssertEqual(store.autoClipHook(id), "Resume me")
        try await until({ self.store.moments.count == 1 }, timeout: 30)
        XCTAssertEqual(store.focusedMoment, id)
        seed(); store.savedProject = store.project; store.resumeSessionOrEdit(); XCTAssertEqual(store.mode, .editor)
    }
    func testStartClippingReusesEmptyProject() {
        store.startClipping(); XCTAssertEqual(store.mode, .clipper); XCTAssertEqual(store.clipStep, .importVOD)
        store.showHome(); XCTAssertEqual(store.mode, .home)
        store.showEditor(); XCTAssertEqual(store.mode, .editor)
    }
    func testClipCaptionsFromKeptRangesAppearInPreparedProject() async throws {
        _ = try await findMoments()
        let candidate = try XCTUnwrap(store.focusedCandidate)
        store.setHook(candidate.id, "Captioned"); store.keepFocused()
        store.updateReview { $0.captions[candidate.id] = [TranscriptSegment(start: candidate.start + 0.2, end: candidate.start + 1, text: "Nice shot")] }
        XCTAssertTrue(try store.preparedAutoClip(candidate, report: store.clipReport!).projectedCaptions().isEmpty, "Captions stay off until enabled")
        store.setClipCaptions(true)
        let segment = try XCTUnwrap(store.review?.captions[candidate.id]?.first)
        store.editClipCaption(candidate.id, segment: segment.id, text: "Nice shot!")
        XCTAssertEqual(try store.preparedAutoClip(candidate, report: store.clipReport!).projectedCaptions().map(\.text), ["Nice shot!"])
        store.nudge(start: true, by: -1)
        XCTAssertNil(store.review?.captions[candidate.id], "Trimming invalidates captions for that clip")
    }
}
