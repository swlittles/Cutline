import XCTest
import AVFoundation
import AppKit
@testable import CutlineCore

final class AutoClipTests: XCTestCase {
    func event(_ t: Double, _ signal: ClipSignal = .audio) -> ClipEvidence { ClipEvidence(time: t, signal: signal, detail: "test") }
    func audioOnly() -> AutoClipSettings { var s = AutoClipSettings(); s.visionEnabled = false; return s }
    func testSilenceAndSteadyLoudSoundProduceNoBursts() {
        for db in [-100.0, -60, -4] { XCTAssertTrue(AutoClipRules.audioEvents((0..<120).map { ClipAudioSample(time: Double($0)/4, db: db) }, settings: audioOnly()).isEmpty) }
    }
    func testAudioBurstUsesRelativeBaselineAndAbsoluteFloor() {
        let samples = (0..<120).map { ClipAudioSample(time: Double($0)/4, db: (40...44).contains($0) ? -12 : -40) }
        let events = AutoClipRules.audioEvents(samples, settings: audioOnly())
        XCTAssertFalse(events.isEmpty); XCTAssertTrue(events.allSatisfy { (10...11).contains($0.time) }); XCTAssertTrue(events[0].detail.contains("28.0 dB above"))
        XCTAssertTrue(AutoClipRules.audioEvents(samples.map { ClipAudioSample(time: $0.time, db: $0.db - 40) }, settings: audioOnly()).isEmpty)
    }
    func testAudioGainDoesNotChangeRelativeTriggerWhenAboveFloor() {
        let samples = (0..<80).map { ClipAudioSample(time: Double($0)/4, db: $0 == 40 ? -10 : -30) }
        XCTAssertEqual(AutoClipRules.audioEvents(samples, settings: audioOnly()).map(\.time), AutoClipRules.audioEvents(samples.map { ClipAudioSample(time: $0.time, db: $0.db - 5) }, settings: audioOnly()).map(\.time))
    }
    func testSparseAndNonfiniteAudioDoesNotCreateEvents() {
        XCTAssertTrue(AutoClipRules.audioEvents([.init(time: 0, db: -80), .init(time: 1, db: -2), .init(time: .nan, db: 0)], settings: audioOnly()).isEmpty)
    }
    func testPixelDifferenceAndSceneCut() {
        XCTAssertEqual(ClipMediaScanner.difference([0,10], [0,10], time: 0).change, 0)
        XCTAssertTrue(ClipMediaScanner.difference([0,0], [255,255], time: 1).sceneCut)
        XCTAssertFalse(ClipMediaScanner.difference([0,0], [255,0], time: 1).sceneCut)
        XCTAssertEqual(ClipMediaScanner.difference([], [], time: 1).change, 0)
    }
    func testIsolatedFlashOrCutIsNotSustainedMotion() {
        let settings = AutoClipSettings()
        XCTAssertTrue(AutoClipRules.motionEvents([.init(time: 1, change: 0), .init(time: 1.5, change: 0.2), .init(time: 2, change: 0)], settings: settings).isEmpty)
        XCTAssertTrue(AutoClipRules.motionEvents([.init(time: 1, change: 0.9, sceneCut: true), .init(time: 1.5, change: 0.9, sceneCut: true)], settings: settings).isEmpty)
    }
    func testMotionNeedsAdjacentSamples() {
        XCTAssertEqual(AutoClipRules.motionEvents([.init(time: 1, change: 0.2), .init(time: 1.5, change: 0.2)], settings: AutoClipSettings()).count, 1)
        XCTAssertTrue(AutoClipRules.motionEvents([.init(time: 1, change: 0.2), .init(time: 8, change: 0.2)], settings: AutoClipSettings()).isEmpty)
    }
    func testCombinedModeRequiresCoincidentSignals() {
        let s = AutoClipSettings()
        XCTAssertTrue(AutoClipRules.candidates(evidence: [event(10), event(30, .motion)], duration: 60, settings: s).isEmpty)
        XCTAssertEqual(AutoClipRules.candidates(evidence: [event(10), event(11, .motion)], duration: 60, settings: s).count, 1)
    }
    func testSingleDetectorAndEitherMode() {
        XCTAssertEqual(AutoClipRules.candidates(evidence: [event(10)], duration: 60, settings: audioOnly()).count, 1)
        var s = AutoClipSettings(); s.requireBoth = false
        XCTAssertEqual(AutoClipRules.candidates(evidence: [event(10, .motion)], duration: 60, settings: s).count, 1)
    }
    func testMarkersWorkWithoutAudioOrOCRMatches() {
        XCTAssertEqual(AutoClipRules.candidates(evidence: [event(10, .marker)], duration: 60, settings: AutoClipSettings()).first?.title, "Marked moment")
    }
    func testMinimumKillsAndRepeatGrouping() {
        XCTAssertTrue(AutoClipRules.candidates(evidence: [event(10, .elimination)], duration: 60, settings: AutoClipSettings()).isEmpty)
        let clips = AutoClipRules.candidates(evidence: [event(10, .elimination),event(18, .elimination)], duration: 60, settings: AutoClipSettings())
        XCTAssertEqual(clips.count, 1); XCTAssertEqual(clips.first?.start, 4); XCTAssertEqual(clips.first?.end, 22)
    }
    func testDeathBreaksEncounterAndPadding() {
        var s = AutoClipSettings(); s.minimumKills = 1
        let clips = AutoClipRules.candidates(evidence: [event(10, .elimination),event(12, .death),event(14, .elimination)], duration: 60, settings: s)
        XCTAssertEqual(clips.count, 2); XCTAssertEqual(clips[0].end, 12); XCTAssertEqual(clips[1].start, 12)
    }
    func testPaddingClampsToRecordingAndCapsCount() {
        var s = audioOnly(); s.maxClips = 1
        let clips = AutoClipRules.candidates(evidence: [event(0),event(59)], duration: 60, settings: s)
        XCTAssertEqual(clips.count, 1); XCTAssertEqual(clips[0].start, 0)
        let end = AutoClipRules.candidates(evidence: [event(59)], duration: 60, settings: s).first!
        XCTAssertEqual(end.end, 60)
    }
    func testMaxDurationAndNoOverlappingCandidates() {
        var s = audioOnly(); s.lead = 2; s.tail = 2; s.maxDuration = 10
        let events = stride(from: 0.0, through: 100, by: 2).map { event($0) }
        let clips = AutoClipRules.candidates(evidence: events, duration: 101, settings: s)
        XCTAssertTrue(clips.allSatisfy { $0.end - $0.start <= 10 })
        for pair in zip(clips, clips.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.end, pair.1.start) }
    }
    func testInvalidTimesDiscardedAndStableSelection() {
        let events = [event(.nan),event(-1),event(200),event(12),event(11)]
        let a = AutoClipRules.candidates(evidence: events, duration: 60, settings: audioOnly())
        XCTAssertEqual(a, AutoClipRules.candidates(evidence: events.reversed(), duration: 60, settings: audioOnly()))
        XCTAssertEqual(a.flatMap(\.evidence).count, 2)
    }
    func testSettingsRejectInvalidRangesNaNAndNoDetectors() {
        var s = AutoClipSettings(); s.audioRiseDB = .nan; XCTAssertThrowsError(try s.validate())
        s = AutoClipSettings(); s.lead = 30; s.tail = 30; XCTAssertThrowsError(try s.validate())
        s = AutoClipSettings(); s.audioEnabled = false; s.visionEnabled = false; XCTAssertThrowsError(try s.validate())
        s = AutoClipSettings(); s.hud.width = 2; XCTAssertThrowsError(try s.validate())
    }
    func testOCRRequiresExplicitCalibrationAndRealAliases() {
        var s = AutoClipSettings(); XCTAssertFalse(s.useOCR); s.useOCR = true
        XCTAssertThrowsError(try s.validate()); s.hudCalibrated = true; s.aliases = "PlayerOne"; XCTAssertNoThrow(try s.validate())
        s.aliases = "You,  "; XCTAssertThrowsError(try s.validate())
    }
    func testGameProfilesMatchReferenceAndNoInventedUnsupportedFeed() {
        XCTAssertEqual(AutoClipSettings.preset(.valorant).aliases, "")
        XCTAssertFalse(ClipGame.tarkov.hasFeedPreset); XCTAssertFalse(ClipGame.wardogs.hasFeedPreset)
        for game in ClipGame.allCases { XCTAssertNoThrow(try AutoClipSettings.preset(game).validate()) }
    }
    func row(_ killer: String = "PlayerOne", _ victim: String = "enemy", gap: Double = 40, confidence: Double = 1) -> [HUDWord] {
        [HUDWord(killer,x: 0,y: 0,width: 100,height: 20,confidence: confidence), HUDWord(victim,x: 100 + gap,y: 0,width: 70,height: 20,confidence: confidence)]
    }
    func testHUDExactIdentityAndVictimIsDeathNotKill() {
        XCTAssertEqual(ClipHUD.parse(row("  PLAYERONE "), aliases: ["PlayerOne"]).first?.death, false)
        XCTAssertEqual(ClipHUD.parse(row("Enemy", "PlayerOne"), aliases: ["PlayerOne"]).first?.death, true)
        XCTAssertTrue(ClipHUD.parse(row("PlayerOne123"), aliases: ["PlayerOne"]).isEmpty)
        XCTAssertTrue(ClipHUD.parse(row("You"), aliases: ["You"]).isEmpty)
    }
    func testHUDRejectsTextWithoutGapLowConfidenceAndAssists() {
        XCTAssertTrue(ClipHUD.parse(row(gap: 5), aliases: ["PlayerOne"]).isEmpty)
        XCTAssertTrue(ClipHUD.parse(row(confidence: 0.7), aliases: ["PlayerOne"]).isEmpty)
        XCTAssertTrue(ClipHUD.parse(row("PlayerOne + ally"), aliases: ["PlayerOne"]).isEmpty)
        XCTAssertTrue(ClipHUD.parse(row("PlayerOne","PlayerOne"), aliases: ["PlayerOne"]).isEmpty)
    }
    func testFeedRequiresTwoTimesAndDeduplicatesPersistentRows() {
        var tracker = ClipFeedTracker(); let reads = ClipHUD.parse(row(), aliases: ["PlayerOne"])
        XCTAssertTrue(tracker.update(at: 0, reads: reads + reads).isEmpty)
        XCTAssertTrue(tracker.update(at: 0, reads: reads).isEmpty)
        XCTAssertEqual(tracker.update(at: 0.5, reads: reads).count, 1)
        for i in 2..<30 { XCTAssertTrue(tracker.update(at: Double(i)/2, reads: reads).isEmpty) }
        XCTAssertTrue(tracker.update(at: 20, reads: reads).isEmpty)
        XCTAssertEqual(tracker.update(at: 20.5, reads: reads).count, 1)
    }
    func testIntermittentReadsDoNotConfirm() {
        var tracker = ClipFeedTracker(); let reads = ClipHUD.parse(row(), aliases: ["PlayerOne"])
        XCTAssertTrue(tracker.update(at: 1, reads: reads).isEmpty)
        XCTAssertTrue(tracker.update(at: 4, reads: reads).isEmpty)
    }
    func testClipProjectPreservesSourceRangeAndRejectsBadRange() throws {
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        var c = AutoClipCandidate(id: "test", start: 4, end: 8, score: 10, evidence: [event(5)])
        let p = try AutoClipRules.project(for: c, media: media)
        XCTAssertEqual(p.duration, 4); XCTAssertEqual(p.clips[0].sourceIn, 4); XCTAssertEqual(p.format, .landscape)
        c.end = 15; XCTAssertThrowsError(try AutoClipRules.project(for: c, media: media))
    }
    func testRealRecordingAudioVisionAndTrackIsolation() async throws {
        let media = try await CompositionEngine.inspect(Fixtures.url("autoclip.mp4").absoluteURL)
        var s = AutoClipSettings(); s.lead = 1; s.tail = 1
        let report = try await ClipMediaScanner.scan(media: media, settings: s)
        XCTAssertEqual(report.candidates.count, 1); XCTAssertGreaterThan(report.sampledFrames, 20); XCTAssertEqual(report.ocrReads, 0)
        XCTAssertTrue(report.evidence.contains { $0.signal == .audio && (5...7).contains($0.time) })
        XCTAssertTrue(report.evidence.contains { $0.signal == .motion && (5...8).contains($0.time) })
        XCTAssertGreaterThanOrEqual(report.candidates[0].start, 4); XCTAssertLessThanOrEqual(report.candidates[0].end, 9)
        s.audioTrack = 1; s.visionEnabled = false
        let quiet = try await ClipMediaScanner.scan(media: media, settings: s)
        XCTAssertTrue(quiet.candidates.isEmpty); XCTAssertEqual(quiet.sampledFrames, 0)
    }
    func testMissingTrackAndChangedSourceAreErrors() async throws {
        var media = try await CompositionEngine.inspect(Fixtures.url("autoclip.mp4").absoluteURL); var s = AutoClipSettings(); s.audioTrack = 9
        do { _ = try await ClipMediaScanner.scan(media: media, settings: s); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("track")) }
        media.duration = 99
        do { _ = try await ClipMediaScanner.scan(media: media, settings: AutoClipSettings()); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("duration changed")) }
    }
    func testScanCancellation() async throws {
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        let task = Task { try await ClipMediaScanner.scan(media: media, settings: AutoClipSettings()) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testBatchProducesPlayableVideoProjectsAndEvidenceWithoutOverwriting() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try await CompositionEngine.inspect(Fixtures.url("autoclip.mp4").absoluteURL)
        let c = AutoClipCandidate(id: "one", start: 4, end: 8, score: 20, evidence: [event(5)])
        let report = AutoClipReport(media: media, settings: AutoClipSettings(), candidates: [c], evidence: c.evidence)
        var options = ProjectSettings(); options.resolution = 720
        let output = try await AutoClipBatch.export(report: report, candidates: [c], to: root, options: options)
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        let video = try XCTUnwrap(files.first { $0.pathExtension == "mp4" })
        let exported = try await CompositionEngine.inspect(video); XCTAssertEqual(exported.duration, 4, accuracy: 0.1)
        let project = try EditProject.read(from: XCTUnwrap(files.first { $0.pathExtension == "cutline" }))
        XCTAssertEqual(project.clips[0].sourceIn, 4); XCTAssertEqual(project.media[0].url, media.url)
        XCTAssertEqual(try JSONDecoder().decode(AutoClipReport.self, from: Data(contentsOf: output.appendingPathComponent("analysis.json"))), report)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".cutline") })
    }
    func testCancelledBatchLeavesNoPartialFolder() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        let c = AutoClipCandidate(id: "one", start: 0, end: 12, score: 1, evidence: [])
        let report = AutoClipReport(media: media, settings: AutoClipSettings(), candidates: [c], evidence: [])
        let task = Task { try await AutoClipBatch.export(report: report, candidates: [c], to: root) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

extension AutoClipTests {
    func testVisionOCRRecognizesSyntheticKillFeed() throws {
        let image = try syntheticHUD()
        let reads = try ClipHUD.read(image, aliases: ["PlayerOne"])
        XCTAssertEqual(reads.first?.killer, "playerone"); XCTAssertEqual(reads.first?.victim, "rival")
        XCTAssertEqual(reads.first?.death, false)
    }
}

extension AutoClipTests {
    func syntheticHUD() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 100, bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 100))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.white]
        NSAttributedString(string: "PlayerOne", attributes: attrs).draw(at: NSPoint(x: 20, y: 30))
        NSAttributedString(string: "Rival", attributes: attrs).draw(at: NSPoint(x: 450, y: 30))
        return try XCTUnwrap(context.makeImage())
    }
}

extension AutoClipTests {
    func testZeroPaddingStillRespectsMaximumDuration() {
        var s = audioOnly(); s.lead = 0; s.tail = 0; s.maxDuration = 3
        let clips = AutoClipRules.candidates(evidence: [event(1),event(4)], duration: 20, settings: s)
        XCTAssertTrue(clips.allSatisfy { $0.end - $0.start <= 3 })
    }
    func testFailedBatchRemovesStagingAndKeepsExistingFiles() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("existing.mp4"); try Data("keep".utf8).write(to: sentinel)
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        let invalid = AutoClipCandidate(id: "bad", start: 10, end: 99, score: 1, evidence: [])
        let report = AutoClipReport(media: media, settings: AutoClipSettings(), candidates: [invalid], evidence: [])
        do { _ = try await AutoClipBatch.export(report: report, candidates: [invalid], to: root); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("range")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.mp4"])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
}
