import XCTest
import CutlineCore
@testable import Cutline

extension EditorStoreTests {
    func autoClipSeed() -> AutoClipReport {
        let media = MediaItem(url: fixture.appendingPathComponent("autoclip.mp4"), duration: 12)
        store.project.media = [media]; store.project.clips = []; store.project.options.resolution = 720
        let c = AutoClipCandidate(id: "one", start: 4, end: 8, score: 50, evidence: [ClipEvidence(time: 5, signal: .audio, detail: "Burst")])
        let report = AutoClipReport(media: media, settings: AutoClipSettings(), candidates: [c], evidence: c.evidence)
        store.clipReport = report; store.selectedAutoClips = [c.id]
        return report
    }
    func testAutomaticClipAppendPreservesTimelineAndSupportsUndo() {
        let report = autoClipSeed(); let before = store.project
        store.addAutoClip(report.candidates[0]); XCTAssertEqual(store.project.clips.count, 1)
        XCTAssertEqual(store.project.clips[0].sourceIn, 4); XCTAssertEqual(store.project.duration, 4)
        store.undo(); XCTAssertEqual(store.project, before)
    }
    func testAutomaticClipRejectsRelinkedSource() {
        let report = autoClipSeed(); store.project.media[0].url = fixture.appendingPathComponent("gameplay.mp4")
        store.addAutoClip(report.candidates[0]); XCTAssertTrue(store.project.clips.isEmpty); XCTAssertNotNil(store.error)
    }
    func testAutomaticScanUsesRecordingWithoutTimelineOrTranscript() async throws {
        _ = autoClipSeed(); store.scanAutoClips()
        try await until({ !self.store.isScanningClips }, timeout: 30)
        XCTAssertNil(store.error); XCTAssertEqual(store.clipReport?.candidates.count, 1)
        XCTAssertTrue(store.project.clips.isEmpty); XCTAssertNil(store.project.transcripts)
        XCTAssertEqual(store.selectedAutoClips.count, 1)
    }
    func testAutomaticScanCancellationAndResetDiscardResults() async throws {
        _ = autoClipSeed(); store.scanAutoClips(); store.clipTask?.cancel()
        try await until { !self.store.isScanningClips }
        XCTAssertNil(store.clipReport); XCTAssertEqual(store.clipMessage, "Scan cancelled.")
        store.scanAutoClips(); store.resetJobs()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.clipReport); XCTAssertFalse(store.isScanningClips)
    }
    func testAutomaticClipInvalidConfigurationDoesNotStart() {
        _ = autoClipSeed(); store.clipSettings.audioRiseDB = .nan; store.scanAutoClips()
        XCTAssertFalse(store.isScanningClips); XCTAssertNotNil(store.error)
    }
    func testAutomaticGameProfilesRetainPerGameEdits() {
        store.selectClipGame(.valorant); store.clipSettings.aliases = "Custom player"
        store.selectClipGame(.cs2); XCTAssertEqual(store.clipSettings.aliases, "")
        store.selectClipGame(.valorant); XCTAssertEqual(store.clipSettings.aliases, "Custom player")
    }
    func testAutomaticBatchExportDoesNotMutateCurrentProject() async throws {
        let report = autoClipSeed(), before = store.project
        store.exportAutoClips(to: root, report: report)
        try await until({ !self.store.isExportingClips }, timeout: 30)
        XCTAssertNil(store.error); XCTAssertNotNil(store.clipOutput); XCTAssertEqual(store.project, before)
        XCTAssertEqual(store.clipMessage, "Exported 1 clip.")
    }
}
