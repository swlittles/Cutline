import XCTest
import AVFoundation
@testable import Cutline
import CutlineCore

@MainActor final class EditorStoreTests: XCTestCase {
    var root: URL!
    var store: EditorStore!
    var fixture: URL { Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures").absoluteURL }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("CUTLINE_TEST_ROOT", root.path, 1)
        guard LocalTools.testingRoot?.path == root.path else { throw XCTSkip("Test isolation requires a Debug build") }
        store = EditorStore()
        XCTAssertEqual(LocalTools.support.path, root.path, "Tests must not use the user's recovery directory")
    }
    override func tearDownWithError() throws {
        store?.resetJobs(); store?.player.pause(); store = nil
        try? FileManager.default.removeItem(at: root); unsetenv("CUTLINE_TEST_ROOT")
    }
    func seed() {
        let media = MediaItem(url: fixture.appendingPathComponent("gameplay.mp4"), duration: 5)
        store.project.media = [media]; store.project.clips = [TimelineClip(mediaID: media.id, sourceOut: 5)]
        store.project.options.resolution = 720; store.selectedClipID = store.project.clips[0].id
        store.savedProject = store.project
    }
    func until(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }
    func testInitialState() {
        XCTAssertFalse(store.dirty); XCTAssertFalse(store.canExport); XCTAssertTrue(store.project.clips.isEmpty)
    }
    func testCommitUndoRedoAndNewEditInvalidatesRedo() {
        store.commit { $0.name = "First" }; XCTAssertTrue(store.dirty)
        store.undo(); XCTAssertEqual(store.project.name, "Untitled project"); XCTAssertFalse(store.redoStack.isEmpty)
        store.redo(); XCTAssertEqual(store.project.name, "First")
        store.undo(); store.commit { $0.name = "Different" }; XCTAssertTrue(store.redoStack.isEmpty)
    }
    func testNoOpCommitDoesNotCreateHistory() {
        store.commit { $0.name = "Untitled project" }; XCTAssertTrue(store.undoStack.isEmpty)
    }
    func testUndoHistoryIsBounded() {
        for index in 0..<150 { store.commit { $0.name = "Project \(index)" } }
        XCTAssertEqual(store.undoStack.count, 100)
    }
    func testSplitUpdatesSelectionAndPreservesDuration() {
        seed(); store.playhead = 2; store.split(); XCTAssertEqual(store.project.clips.count, 2)
        XCTAssertEqual(store.selectedClipID, store.project.clips[1].id); XCTAssertEqual(store.project.duration, 5)
    }
    func testDuplicateCopiesOnlyRelevantCaptionsAndDeleteCleansThem() {
        seed(); store.project.generateCaptions(from: SourceTranscript(mediaID: store.project.media[0].id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 1, end: 2, text: "Hello")]))
        store.duplicate(); XCTAssertEqual(store.project.captionTrack?.cues.count, 2)
        store.deleteSelected(); XCTAssertEqual(store.project.captionTrack?.cues.count, 1); XCTAssertNil(store.selectedClipID)
        store.undo(); XCTAssertEqual(store.project.captionTrack?.cues.count, 2)
    }
    func testReorderSelectedAndDragDestination() {
        seed(); store.duplicate(); let second = store.selectedClipID!; store.moveSelected(-1); XCTAssertEqual(store.project.clips[0].id, second)
        let first = store.project.clips[1].id; store.moveClip(first, before: second); XCTAssertEqual(store.project.clips[0].id, first)
    }
    func testReorderBoundariesAreNoOps() {
        seed(); store.moveSelected(-1); store.moveSelected(1); XCTAssertTrue(store.undoStack.isEmpty)
        store.moveClip(UUID(), before: store.project.clips[0].id); XCTAssertEqual(store.project.clips.count, 1)
    }
    func testTrimClampsToSourceAndRejectsNonfiniteValues() {
        seed(); let id = store.selectedClipID!
        store.updateClip(id, sourceIn: -10, sourceOut: 99, volume: 99)
        XCTAssertEqual(store.selectedClip?.sourceIn, 0); XCTAssertEqual(store.selectedClip?.sourceOut, 5); XCTAssertEqual(store.selectedClip?.volume, 2)
        let before = store.project; store.updateClip(id, sourceIn: .nan); XCTAssertEqual(store.project, before)
    }
    func testUpdatingUnselectedClipUsesItsOwnMediaDuration() {
        seed(); let other = MediaItem(url: fixture.appendingPathComponent("facecam.mp4"), duration: 3)
        store.project.media.append(other); let clip = TimelineClip(mediaID: other.id, sourceOut: 3); store.project.clips.append(clip)
        store.updateClip(clip.id, sourceOut: 8); XCTAssertEqual(store.project.clips[1].sourceOut, 3)
    }
    func testTrimAtPlayheadAccountsForSpeed() {
        seed(); store.project.clips[0].adjustments = ClipAdjustments(); store.project.clips[0].adjustments?.speed = 2
        store.playhead = 1; store.trimToPlayhead(start: true); XCTAssertEqual(store.project.clips[0].sourceIn, 2)
    }
    func testInvalidAdjustmentDoesNotMutateProject() {
        seed(); let before = store.project
        store.updateAdjustments(store.selectedClipID!) { $0.speed = 0 }
        XCTAssertEqual(store.project, before); XCTAssertNotNil(store.error)
    }
    func testAddCaptionAtPlayheadAndInvalidCaptionEdit() {
        seed(); store.playhead = 1; store.addCaption(); XCTAssertEqual(store.project.captionTrack?.cues.count, 1)
        let cue = store.project.captionTrack!.cues[0]; store.editCaption(cue.id, text: "Changed", start: 1.5, end: 2.5)
        XCTAssertEqual(store.project.captionTrack?.cues[0].text, "Changed")
        let before = store.project; store.editCaption(cue.id, text: "", start: 3, end: 2); XCTAssertEqual(store.project, before); XCTAssertNotNil(store.error)
    }
    func testWhitespaceCaptionEditDoesNotCorruptProject() {
        seed(); store.addCaption(); let before = store.project
        store.editCaption(store.project.captionTrack!.cues[0].id, text: "  ")
        XCTAssertEqual(store.project, before); XCTAssertNotNil(store.error)
    }
    func testCaptionBeyondTimelineIsNotAdded() {
        seed(); store.playhead = 5; store.addCaption(); XCTAssertNil(store.project.captionTrack)
    }
    func testHighlightMarkerAndOverlayBoundToPlayhead() {
        seed(); store.playhead = 2; store.addMarker(); XCTAssertEqual(store.project.markers?[0].sourceTime, 2)
        store.addOverlay(store.project.media[0]); XCTAssertEqual(store.project.overlays?[0].start, 2); XCTAssertEqual(store.project.overlays?[0].duration, 3)
    }
    func testOverlayOutsideTimelineIsRejected() {
        seed(); store.playhead = 5; store.addOverlay(store.project.media[0]); XCTAssertNil(store.project.overlays); XCTAssertNotNil(store.error)
    }
    func testTranscriptCutIsUndoableAndInvalidCutLeavesState() {
        seed(); let before = store.project
        store.cutRanges([TimelineRange(start: 1, end: 3)]); XCTAssertEqual(store.project.duration, 3)
        store.undo(); XCTAssertEqual(store.project, before)
        store.cutRanges([TimelineRange(start: 0, end: 5)]); XCTAssertEqual(store.project, before); XCTAssertNotNil(store.error)
    }
    func testSaveAndLoadRoundTripClearsDirtyState() throws {
        seed(); store.projectURL = root.appendingPathComponent("Saved.cutline"); store.commit { $0.format = .square }
        XCTAssertTrue(store.save()); XCTAssertFalse(store.dirty)
        let saved = store.project; store.project = EditProject(); store.loadProject(store.projectURL!)
        XCTAssertEqual(store.project, saved); XCTAssertTrue(store.undoStack.isEmpty)
    }
    func testAutosaveDebouncesToLatestEdit() async throws {
        store.commit { $0.name = "Old" }; store.commit { $0.name = "Latest" }
        try await until { FileManager.default.fileExists(atPath: self.store.recoveryURL.path) }
        XCTAssertEqual(try EditProject.read(from: store.recoveryURL).name, "Latest")
    }
    func testSaveCancelsPendingRecoveryWrite() async throws {
        store.projectURL = root.appendingPathComponent("Saved.cutline"); store.commit { $0.name = "Changed" }; XCTAssertTrue(store.save())
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recoveryURL.path))
    }
    func testRecoveryLoadsSnapshotAsUnsavedAndCanBeSaved() throws {
        var recovered = EditProject(); recovered.name = "Recovered"
        try FileManager.default.createDirectory(at: store.recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true); try recovered.write(to: store.recoveryURL)
        store.recoverAutosave(); XCTAssertEqual(store.project.name, "Recovered"); XCTAssertTrue(store.dirty)
        store.projectURL = root.appendingPathComponent("Recovered.cutline"); XCTAssertTrue(store.save()); XCTAssertFalse(FileManager.default.fileExists(atPath: store.recoveryURL.path))
    }
    func testCorruptRecoveryDoesNotReplaceCurrentProject() throws {
        try FileManager.default.createDirectory(at: store.recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad JSON".utf8).write(to: store.recoveryURL); let before = store.project
        store.recoverAutosave(); XCTAssertEqual(store.project, before); XCTAssertNotNil(store.error)
    }
    func testJobResetCancelsWorkAndInvalidatesStaleResponses() async {
        let oldEpoch = store.projectEpoch
        store.isThinking = true; store.isTranscribing = true
        let task = Task<Void,Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }; store.assistantTask = task
        store.resetJobs(); XCTAssertTrue(task.isCancelled); XCTAssertFalse(store.isThinking); XCTAssertFalse(store.isTranscribing); XCTAssertNotEqual(store.projectEpoch, oldEpoch)
    }
    func testStaleAIProposalCannotChangeEditedTimeline() throws {
        seed(); store.aiSnapshot = store.project
        let data = Data("{\"start\":0,\"end\":2,\"title\":\"Moment\",\"reason\":\"Speech\",\"score\":80}".utf8)
        let highlight = try JSONDecoder().decode(AIHighlight.self, from: data)
        store.commit { $0.name = "Changed" }; let before = store.project; store.applyHighlight(highlight)
        XCTAssertEqual(store.project, before); XCTAssertNotNil(store.error)
    }
    func testHighlightApplicationIsUndoable() throws {
        seed(); let before = store.project; store.aiSnapshot = before
        let data = Data("{\"start\":1,\"end\":3,\"title\":\"Moment\",\"reason\":\"Speech\",\"score\":80}".utf8)
        store.applyHighlight(try JSONDecoder().decode(AIHighlight.self, from: data))
        XCTAssertEqual(store.project.name, "Moment"); XCTAssertEqual(store.project.duration, 2)
        store.undo(); XCTAssertEqual(store.project, before)
    }
    func testImportDeduplicatesURLsAndReportsUnreadableInputs() async throws {
        store.importURLs([fixture.appendingPathComponent("gameplay.mp4"),fixture.appendingPathComponent("gameplay.mp4"),root.appendingPathComponent("missing.mp4")])
        try await until { !self.store.isImporting }
        XCTAssertEqual(store.project.media.count, 1); XCTAssertNotNil(store.error)
    }
    func testAudioImportCreatesLayerAtRequestedTime() async throws {
        seed(); store.playhead = 1; store.insertAudio(fixture.appendingPathComponent("music.m4a"))
        try await until { self.store.project.music?.count == 1 }
        XCTAssertEqual(store.project.music?[0].start, 1)
    }
    func testPreviewBuildGatesExportAndLoadsPlayer() async throws {
        seed(); store.rebuild(); XCTAssertFalse(store.canExport)
        try await until { !self.store.isBuilding }; XCTAssertTrue(store.canExport); XCTAssertNotNil(store.player.currentItem)
        store.seek(-2); XCTAssertEqual(store.playhead, 0); store.seek(100); XCTAssertEqual(store.playhead, 5)
    }
}
