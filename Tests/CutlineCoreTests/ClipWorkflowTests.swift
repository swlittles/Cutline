import XCTest
import AVFoundation
@testable import CutlineCore

final class ClipWorkflowTests: XCTestCase {
    private func recording() async throws -> MediaItem {
        var media = try await CompositionEngine.inspect(Fixtures.url("autoclip.mp4"))
        media.shortFraming = ShortFraming(); media.shortFraming?.confirmed = true
        return media
    }
    private func quick() -> AutoClipSettings { var s = AutoClipSettings(); s.lead = 1; s.tail = 1; return s }

    // MARK: Measure once, evaluate many times
    func testAnalysisMatchesScannerAndMeasuresEveryTrackInOnePass() async throws {
        let media = try await recording(), settings = quick()
        let scanned = try await ClipMediaScanner.scan(media: media, settings: settings)
        let analysis = try await ClipAnalyzer.analyze(media: media, settings: settings)
        XCTAssertEqual(analysis.audioTracks?.keys.sorted(), [0, 1])
        let report = try analysis.report(settings: settings)
        XCTAssertEqual(report.candidates, scanned.candidates)
        XCTAssertEqual(report.audioSamples, scanned.audioSamples)
        XCTAssertEqual(report.motionSamples, scanned.motionSamples)
        XCTAssertEqual(report.sampledFrames, scanned.sampledFrames)
    }
    func testThresholdAndTrackChangesNeedNoNewMeasurement() async throws {
        let media = try await recording()
        let analysis = try await ClipAnalyzer.analyze(media: media, settings: quick())
        var quiet = quick(); quiet.audioTrack = 1; quiet.visionEnabled = false
        XCTAssertTrue(analysis.covers(quiet)); XCTAssertTrue(try analysis.report(settings: quiet).candidates.isEmpty)
        var picky = quick(); picky.sensitivity = 0; XCTAssertTrue(analysis.covers(picky))
        var moved = quick(); moved.motionRegion.x = 0.1; XCTAssertFalse(analysis.covers(moved))
        XCTAssertThrowsError(try analysis.report(settings: moved))
        var faster = quick(); faster.sampleFPS = 3; XCTAssertFalse(analysis.covers(faster))
        var audioOnly = moved; audioOnly.visionEnabled = false; XCTAssertTrue(analysis.covers(audioOnly))
    }
    func testIncrementalAnalysisOnlySamplesWhatIsMissing() async throws {
        let media = try await recording()
        var audioOnly = quick(); audioOnly.visionEnabled = false
        let first = try await ClipAnalyzer.analyze(media: media, settings: audioOnly)
        XCTAssertNil(first.visual); XCTAssertEqual(first.sampledFrames, 0)
        let second = try await ClipAnalyzer.analyze(media: media, settings: quick(), existing: first)
        XCTAssertEqual(second.audioTracks, first.audioTracks); XCTAssertGreaterThan(second.sampledFrames, 20)
        let third = try await ClipAnalyzer.analyze(media: media, settings: quick(), existing: second)
        XCTAssertEqual(third, second)
    }
    func testAnalysisRejectsChangedSourceAndMissingTrack() async throws {
        var media = try await recording(); media.duration = 30
        do { _ = try await ClipAnalyzer.analyze(media: media, settings: quick()); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("duration changed")) }
        media = try await recording()
        var s = quick(); s.audioTrack = 5
        do { _ = try await ClipAnalyzer.analyze(media: media, settings: s); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("track")) }
    }
    /// Recorders often stop video a few frames before audio. Asking for a frame in that tail
    /// fails with "Cannot Open", which used to fail the whole scan at its very last sample.
    func testVisualSamplingStopsAtTheLastVideoFrame() async throws {
        let media = try await CompositionEngine.inspect(Fixtures.url("audio-outlasts-video.mp4"))
        XCTAssertGreaterThan(media.duration, 4.2)
        let analysis = try await ClipAnalyzer.analyze(media: media, settings: AutoClipSettings())
        XCTAssertEqual(analysis.sampledFrames, 8)
        XCTAssertLessThan(try XCTUnwrap(analysis.motionSamples.last).time, 4)
        let scanned = try await ClipMediaScanner.scan(media: media, settings: AutoClipSettings())
        XCTAssertEqual(scanned.sampledFrames, 8)
    }
    func testAnalysisCancellation() async throws {
        let media = try await recording()
        let task = Task { try await ClipAnalyzer.analyze(media: media, settings: AutoClipSettings()) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testMarkersBecomeMomentsWithoutOtherEvidence() async throws {
        let media = try await recording()
        var s = quick(); s.audioEnabled = false; s.visionEnabled = false; s.useOCR = false
        var analysis = ClipAnalysis(media: media); analysis.audioTracks = [:]
        XCTAssertThrowsError(try analysis.report(settings: s), "No detector enabled")
        s.audioEnabled = true; analysis.audioTracks = [0: [], 1: []]; s.visionEnabled = false
        let report = try analysis.report(settings: s, markers: [ClipEvidence(time: 9, signal: .marker, detail: "Mine"), ClipEvidence(time: 99, signal: .marker, detail: "Outside")])
        XCTAssertEqual(report.candidates.count, 1); XCTAssertEqual(report.candidates[0].title, "Marked moment")
    }
    func testAnalysisCacheRoundTripAndInvalidation() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try await recording()
        let analysis = try await ClipAnalyzer.analyze(media: media, settings: quick())
        try ClipAnalysisCache.save(analysis, root: root)
        var other = media; other.id = UUID()
        let loaded = try XCTUnwrap(ClipAnalysisCache.load(for: other, root: root))
        XCTAssertEqual(loaded.media, other, "Measurements attach to the file, not a project identifier")
        XCTAssertEqual(loaded.audioTracks, analysis.audioTracks); XCTAssertEqual(loaded.motionSamples, analysis.motionSamples)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Analysis"), includingPropertiesForKeys: nil).first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var changed = media; changed.duration += 1
        XCTAssertNil(ClipAnalysisCache.load(for: changed, root: root))
    }

    // MARK: Sensitivity
    func testSensitivityMidpointIsDefaultAndExtremesAreValid() {
        var s = AutoClipSettings(); XCTAssertEqual(s.sensitivity, 0.5, accuracy: 0.001)
        s.sensitivity = 0.5; XCTAssertEqual(s, AutoClipSettings())
        var previous = AutoClipSettings(); previous.sensitivity = 0
        XCTAssertNoThrow(try previous.validate())
        for value in stride(from: 0.1, through: 1, by: 0.1) {
            var next = AutoClipSettings(); next.sensitivity = value
            XCTAssertNoThrow(try next.validate())
            XCTAssertLessThan(next.audioRiseDB, previous.audioRiseDB); XCTAssertLessThanOrEqual(next.motionThreshold, previous.motionThreshold)
            XCTAssertEqual(next.sensitivity, value, accuracy: 0.02)
            previous = next
        }
        s.sensitivity = .nan; XCTAssertEqual(s.sensitivity, 0.5, accuracy: 0.001)
    }

    // MARK: Audio roles
    func testAudioRoutesNeverDoubleTheMixAndPreferIsolatedTracks() {
        XCTAssertEqual(AudioRoutes([.mix, .mic, .game]), { var r = AudioRoutes([]); r.detect = 1; r.export = [0]; r.speech = 1; return r }())
        let isolated = AudioRoutes([.ignore, .mic, .game])
        XCTAssertEqual(isolated.export, [1, 2]); XCTAssertEqual(isolated.detect, 1); XCTAssertEqual(isolated.speech, 1)
        let gameOnly = AudioRoutes([.mix, .game])
        XCTAssertEqual(gameOnly.detect, 1); XCTAssertEqual(gameOnly.speech, 0); XCTAssertEqual(gameOnly.export, [0])
        XCTAssertEqual(AudioRoutes([]).export, [0])
    }
    func testAudioRoleGuessUsesTrackNamesThenPosition() {
        XCTAssertEqual(AudioRole.guess(count: 1), [.mix])
        XCTAssertEqual(AudioRole.guess(count: 4), [.mix, .mic, .game, .ignore])
        XCTAssertEqual(AudioRole.guess(count: 3, names: ["Desktop Audio", nil, "Mic/Aux"]), [.game, .mic, .mic])
        XCTAssertEqual(AudioRole.guess(count: 0), [])
    }
    func testMultiTrackExportGainsAndValidation() throws {
        var media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12); media.audioTrackCount = 3; media.audioRoles = [.mix, .mic, .game]
        let candidate = AutoClipCandidate(id: "a", start: 1, end: 5, score: 1, evidence: [])
        let project = try AutoClipRules.project(for: candidate, media: media, outputAudioTracks: [1, 2])
        XCTAssertEqual(project.clips[0].adjustments?.audioGains, ["0": 0, "1": 1, "2": 1])
        XCTAssertNil(project.media[0].audioRoles)
        XCTAssertThrowsError(try AutoClipRules.project(for: candidate, media: media, outputAudioTracks: [3]))
        XCTAssertThrowsError(try AutoClipRules.project(for: candidate, media: media, outputAudioTracks: []))
        var s = AutoClipSettings(); s.outputAudioTracks = [2, 1, 2]; XCTAssertEqual(s.exportTracks, [1, 2]); XCTAssertNoThrow(try s.validate())
        s.outputAudioTracks = []; XCTAssertThrowsError(try s.validate())
    }

    // MARK: Scene presets
    func testScenePresetsPersistPrivatelyAndConfirmCrops() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try ScenePresetStore.load(from: root), [])
        var framing = ShortFraming(); framing.camera.x = 0.6
        let preset = ScenePreset(name: "Valorant main", framing: framing, audioRoles: [.mix, .mic], game: .valorant, motionRegion: ClipScanRegion(x: 0, y: 0, width: 0.5, height: 0.5))
        try ScenePresetStore.save([preset], to: root)
        XCTAssertEqual(try ScenePresetStore.load(from: root), [preset])
        let path = root.appendingPathComponent("scene-presets.json").path
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12); media.audioTrackCount = 3
        preset.apply(to: &media)
        XCTAssertEqual(media.shortFraming?.camera.x, 0.6); XCTAssertEqual(media.shortFraming?.confirmed, true)
        XCTAssertEqual(media.audioRoles, [.mix, .mic, .ignore])
        var bad = preset; bad.name = "  "; XCTAssertThrowsError(try ScenePresetStore.save([bad], to: root))
        XCTAssertThrowsError(try ScenePresetStore.save([preset, preset], to: root))
    }

    // MARK: Review state
    func testReviewDecisionsTrimsAndMoments() {
        var review = ClipReview(mediaID: UUID())
        review.decide("a", .kept); review.decide("b", .skipped)
        XCTAssertEqual(review.decision("a"), .kept); XCTAssertEqual(review.decision("b"), .skipped); XCTAssertEqual(review.decision("c"), .undecided)
        review.decide("a", .skipped); XCTAssertEqual(review.kept, []); XCTAssertEqual(review.skipped, ["b", "a"])
        review.decide("a", .undecided); XCTAssertEqual(review.skipped, ["b"])
        let candidate = AutoClipCandidate(id: "a", start: 10, end: 20, score: 1, evidence: [])
        review.captions["a"] = [TranscriptSegment(start: 11, end: 12, text: "hi")]
        review.setRange("a", start: 8, end: 21, duration: 60)
        XCTAssertEqual(review.applied(candidate).start, 8); XCTAssertEqual(review.applied(candidate).end, 21); XCTAssertEqual(review.applied(candidate).id, "a")
        XCTAssertNil(review.captions["a"], "A new range invalidates its captions")
        review.setRange("a", start: 15, end: 15.2, duration: 60)
        XCTAssertEqual(review.ranges["a"], ClipRange(start: 15, end: 16), "Clips keep a minimum length")
        review.setRange("a", start: -5, end: 3, duration: 60); XCTAssertEqual(review.ranges["a"], ClipRange(start: 0, end: 8))
        review.setRange("a", start: 58, end: 70, duration: 60); XCTAssertEqual(review.ranges["a"], ClipRange(start: 48, end: 60))
        review.setRange("a", start: 0, end: 500, duration: 600); XCTAssertEqual(review.ranges["a"]?.end, 180)
        review.setRange("a", start: .nan, end: 3, duration: 60); XCTAssertEqual(review.ranges["a"]?.end, 180)
        review.addMoment(5, duration: 60); review.addMoment(5.2, duration: 60); review.addMoment(61, duration: 60); review.addMoment(2, duration: 60)
        XCTAssertEqual(review.moments, [2, 5])
    }
    func testReviewPersistsInProjectAndValidates() throws {
        let folder = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        var project = EditProject(workflow: .mobileShort)
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        project.media = [media]
        var review = ClipReview(mediaID: media.id); review.decide("x", .kept); review.moments = [3]
        review.ranges["x"] = ClipRange(start: 1, end: 4); review.captionsEnabled = true
        project.clipReview = review
        let url = folder.appendingPathComponent("session.cutline"); try project.write(to: url)
        XCTAssertEqual(try EditProject.read(from: url).clipReview, review)
        project.clipReview?.ranges["x"] = ClipRange(start: 1, end: 40); XCTAssertThrowsError(try project.validate())
        project.clipReview = review; project.clipReview?.moments = [.infinity]; XCTAssertThrowsError(try project.validate())
        let minimal = try JSONDecoder().decode(ClipReview.self, from: Data("{\"mediaID\":\"\(media.id)\"}".utf8))
        XCTAssertEqual(minimal, ClipReview(mediaID: media.id))
    }
    func testClipProjectCarriesHookCaptionsAndTracks() throws {
        var media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12); media.audioTrackCount = 2
        media.shortFraming = ShortFraming(); media.shortFraming?.confirmed = true
        var settings = AutoClipSettings(); settings.outputAudioTracks = [1]
        let candidate = AutoClipCandidate(id: "a", start: 2, end: 8, score: 1, evidence: [])
        let report = AutoClipReport(media: media, settings: settings, candidates: [candidate], evidence: [])
        let segments = [TranscriptSegment(start: 3, end: 4, text: "Inside"), TranscriptSegment(start: 9, end: 10, text: "Outside")]
        let project = try AutoClipBatch.clipProject(candidate, report: report, options: ProjectSettings(), hook: "Hook", captions: segments)
        XCTAssertEqual(project.shortHook, "Hook"); XCTAssertEqual(project.projectedCaptions().map(\.text), ["Inside"])
        XCTAssertEqual(project.clips[0].adjustments?.audioGains, ["0": 0, "1": 1])
        XCTAssertNoThrow(try project.validateForExport())
        XCTAssertEqual(AutoClipBatch.fileName("a/b: c?\n"), "a-b- c")
        XCTAssertEqual(AutoClipBatch.fileName("..."), "Clip")
    }
    func testHookIdeasAreShortAndUseEvidence() {
        let kills = AutoClipCandidate(id: "k", start: 0, end: 12, score: 80, evidence: [ClipEvidence(time: 1, signal: .elimination, detail: ""), ClipEvidence(time: 2, signal: .elimination, detail: "")])
        let ideas = HookIdeas.suggestions(for: kills, game: .valorant)
        XCTAssertEqual(ideas.first, "2 kills in 12 seconds"); XCTAssertTrue(ideas.contains("This is why I play Valorant"))
        XCTAssertTrue(ideas.allSatisfy { !$0.isEmpty && $0.count <= 80 }); XCTAssertLessThanOrEqual(ideas.count, 5)
    }
    func testClockTime() {
        XCTAssertEqual(clockTime(0), "0:00"); XCTAssertEqual(clockTime(65.9), "1:05"); XCTAssertEqual(clockTime(3725), "1:02:05"); XCTAssertEqual(clockTime(.nan), "0:00")
    }
}

final class RangeTranscriptionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Models"), withIntermediateDirectories: true)
        setenv("CUTLINE_TEST_ROOT", root.path, 1)
        guard LocalTools.testingRoot?.path == root.path else { throw XCTSkip("Test isolation requires a Debug build") }
        try Data("fixture".utf8).write(to: WhisperModel.base.file)
        let script = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          case "$1" in -f) shift; input="$1" ;; -of) shift; output="$1" ;; esac
          shift
        done
        cp "$input" "$CUTLINE_TEST_ROOT/captured.wav"
        cat > "$output.srt" <<'SRT'
        1
        00:00:00,300 --> 00:00:01,400
        Only this clip.
        SRT
        """
        let file = root.appendingPathComponent("Helpers/whisper-cli")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root); unsetenv("CUTLINE_TEST_ROOT") }
    func testRangeTranscribesOnlyThatPartWithSourceTimes() async throws {
        guard LocalTools.executable("ffmpeg") != nil else { throw XCTSkip("ffmpeg is required") }
        let media = MediaItem(url: Fixtures.url("gameplay.mp4"), duration: 5)
        let transcript = try await LocalTranscription.transcribe(media: media, audioTrack: 0, model: .base, range: ClipRange(start: 2, end: 3.5), progress: { _ in })
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].start, 2.3, accuracy: 0.001); XCTAssertEqual(transcript.segments[0].end, 3.4, accuracy: 0.001)
        let file = try AVAudioFile(forReading: root.appendingPathComponent("captured.wav"))
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1.5, accuracy: 0.05, "Only the kept range is decoded")
        do { _ = try await LocalTranscription.transcribe(media: media, audioTrack: 0, model: .base, range: ClipRange(start: 4, end: 4), progress: { _ in }); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("range")) }
    }
}

final class MediaConversionTests: XCTestCase {
    func testOBSFormatsConvertAndExistingMP4IsReused() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let mkv = root.appendingPathComponent("Friday stream.MKV")
        XCTAssertTrue(MediaConversion.needsConversion(mkv)); XCTAssertTrue(MediaConversion.needsConversion(root.appendingPathComponent("a.flv")))
        XCTAssertFalse(MediaConversion.needsConversion(root.appendingPathComponent("a.mp4")))
        XCTAssertEqual(MediaConversion.destination(for: mkv).url.lastPathComponent, "Friday stream.mp4")
        XCTAssertFalse(MediaConversion.destination(for: mkv).existing)
        // OBS's own remux (or an earlier import) already made the MP4: use it rather than copying gigabytes again.
        try Data().write(to: root.appendingPathComponent("Friday stream.mp4"))
        XCTAssertTrue(MediaConversion.destination(for: mkv).existing)
        XCTAssertTrue(MediaConversion.missingConverterMessage(mkv).contains("Remux Recordings"))
    }
    func testRemuxKeepsEveryAudioTrack() async throws {
        guard LocalTools.executable("ffmpeg") != nil else { throw XCTSkip("ffmpeg is not installed") }
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let mkv = root.appendingPathComponent("stream.mkv")
        _ = try await ProcessRunner.run(LocalTools.executable("ffmpeg")!, ["-hide_banner", "-loglevel", "error", "-y", "-i", Fixtures.url("autoclip.mp4").path, "-map", "0", "-c", "copy", mkv.path])
        let mp4 = try await MediaConversion.convertToMP4(mkv)
        XCTAssertEqual(mp4.lastPathComponent, "stream.mp4")
        let original = try await CompositionEngine.inspect(Fixtures.url("autoclip.mp4").absoluteURL), converted = try await CompositionEngine.inspect(mp4)
        XCTAssertEqual(converted.audioTrackCount, original.audioTrackCount); XCTAssertEqual(converted.duration, original.duration, accuracy: 0.1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".") }, "No partial file is left behind")
    }
}

final class MomentTitleTests: XCTestCase {
    func testTitlesUsePlainWords() {
        let make = { (signals: [ClipSignal]) in AutoClipCandidate(id: "x", start: 0, end: 5, score: 1, evidence: signals.map { ClipEvidence(time: 1, signal: $0, detail: "") }) }
        XCTAssertEqual(make([.audio, .motion]).title, "Big reaction during action")
        XCTAssertEqual(make([.audio]).title, "Big reaction")
        XCTAssertEqual(make([.motion]).title, "Lots of action")
        XCTAssertEqual(make([.elimination, .elimination]).title, "2 eliminations")
        XCTAssertEqual(make([.marker]).title, "Marked moment")
    }
}
