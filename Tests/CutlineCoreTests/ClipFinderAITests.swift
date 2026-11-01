import XCTest
@testable import CutlineCore

private final class PlanStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var content = "{\"clips\":[]}"
    nonisolated(unsafe) static var copyContent = "{}"
    nonisolated(unsafe) static var visionContent = "{\"frames\":[]}"
    nonisolated(unsafe) static var copyStatus = 200
    nonisolated(unsafe) static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
            stream.close(); Self.bodies.append(data)
        }
        // Each AI step names its schema, so one stub can answer all three.
        let body = String(decoding: Self.bodies.last ?? Data(), as: UTF8.self)
        let copy = body.contains("clip_copy"), vision = body.contains("frame_notes")
        let response = HTTPURLResponse(url: request.url!, statusCode: copy ? Self.copyStatus : Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let payload = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": copy ? Self.copyContent : vision ? Self.visionContent : Self.content]]]])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClipFinderAITests: XCTestCase {
    func session() -> URLSession { let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PlanStub.self]; return URLSession(configuration: configuration) }
    func transcript(_ lines: [(Double, Double, String)]) -> StreamTranscript {
        StreamTranscript(audioTrack: 1, engine: "test", segments: lines.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) })
    }
    func clip(_ start: String, _ end: String, title: String = "Missed the easiest shot", ratings: Double = 8) -> String {
        let scores = ["hook", "payoff", "arousal", "pacing", "clarity", "novelty", "strangerRelevance", "commentability"].map { "\"\($0)\":\(ratings)" }.joined(separator: ",")
        return "{\"start\":\"\(start)\",\"end\":\"\(end)\",\"title\":\"\(title)\",\"hook\":\"Wait for the reload\",\"reason\":\"laughing + audio spike\",\"viralityReason\":\"clean payoff\",\"scores\":{\(scores)}}"
    }

    func testTranscriptTextCaptionsAndCacheRoundTrip() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let spoken = transcript([(1, 3, "no way"), (4, 6, "that actually worked"), (20, 22, "later")])
        XCTAssertEqual(spoken.text(from: 2, to: 5), "no way that actually worked")
        let captions = spoken.captions(from: 2, to: 5)
        XCTAssertEqual(captions.map(\.start), [2, 4]); XCTAssertEqual(captions.map(\.end), [3, 5])
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        XCTAssertNil(StreamTranscriptCache.load(for: media, track: 1, root: root))
        try StreamTranscriptCache.save(spoken, for: media, root: root)
        XCTAssertEqual(StreamTranscriptCache.load(for: media, track: 1, root: root), spoken)
        XCTAssertNil(StreamTranscriptCache.load(for: media, track: 0, root: root), "Each speech track has its own transcript")
        let picks = AIClipPicks(audioTrack: 1, model: "test/model", picks: [AIClipPick(start: 1, end: 9, title: "t", hook: "h", reason: "r", score: 70)])
        try AIClipPicksCache.save(picks, for: media, root: root)
        XCTAssertEqual(AIClipPicksCache.load(for: media, track: 1, root: root), picks)
        AIClipPicksCache.remove(for: media, track: 1, root: root)
        XCTAssertNil(AIClipPicksCache.load(for: media, track: 1, root: root))
        XCTAssertEqual(StreamTranscriptCache.load(for: media, track: 1, root: root), spoken, "Removing picks keeps the transcript")
    }

    func testInventedRepeatsAndEmptyLinesAreDropped() {
        var lines: [TranscriptSegment] = []
        for i in 0..<10 { lines.append(TranscriptSegment(start: Double(i) * 2, end: Double(i) * 2 + 1, text: i % 2 == 0 ? "I'm going on a trip to the West" : "Coast.")) }
        lines.append(TranscriptSegment(start: 30, end: 31, text: "."))
        lines.append(TranscriptSegment(start: 200, end: 201, text: "Coast."))
        let kept = StreamTranscript.withoutLoops(lines)
        XCTAssertEqual(kept.filter { $0.text == "Coast." }.count, 3, "Twice in a loop, and again much later")
        XCTAssertEqual(kept.filter { $0.text.hasPrefix("I'm going") }.count, 2)
        XCTAssertFalse(kept.contains { $0.text == "." })
    }
    func testSectionsSplitLongStreamsWithOverlap() {
        XCTAssertEqual(ClipFinderAI.sections(duration: 3600).count, 1)
        let sections = ClipFinderAI.sections(duration: 3 * 3600)
        XCTAssertEqual(sections.first?.start, 0); XCTAssertEqual(sections.last?.end, 3 * 3600)
        for (a, b) in zip(sections, sections.dropFirst()) { XCTAssertEqual(a.end - b.start, 120, accuracy: 0.001) }
        XCTAssertTrue(sections.allSatisfy { $0.end - $0.start <= 2400 })
    }

    func testTimelineJoinsSpeechMarksClipItAndKeepsStrongestSignals() {
        let spoken = transcript([(5, 6, "okay okay"), (6.2, 8, "clip it, chat"), (30, 31, "quiet bit with \"quotes\"")])
        let signals = [ClipEvidence(time: 6, signal: .audio, strength: 0.4, detail: ""), ClipEvidence(time: 7, signal: .audio, strength: 0.9, detail: ""),
                       ClipEvidence(time: 20, signal: .motion, strength: 0.5, detail: ""), ClipEvidence(time: 25, signal: .marker, detail: "Marked by you")]
        let lines = ClipFinderAI.timeline(transcript: spoken, signals: signals, in: ClipRange(start: 0, end: 60)).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "[00:00:05] \"okay okay clip it, chat\"", "Close caption lines become one utterance")
        XCTAssertTrue(lines.contains { $0.contains("VOICE MARKER") })
        XCTAssertEqual(lines.filter { $0.contains("(audio:") }, ["[00:00:07] (audio: loud reaction on the streamer's track, intensity 0.90)"], "A burst is one line at its peak")
        XCTAssertTrue(lines.contains("[00:00:20] (screen: busy on-screen action, intensity 0.50)"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("[00:00:25] (MARKED") })
        XCTAssertTrue(lines.contains("[00:00:30] \"quiet bit with 'quotes'\""))
        XCTAssertEqual(lines.map { $0.prefix(10) }, lines.map { $0.prefix(10) }.sorted())
        XCTAssertFalse(ClipFinderAI.timeline(transcript: spoken, signals: signals, in: ClipRange(start: 10, end: 60)).contains("okay okay"))
    }

    func testRequestIsStructuredAndCarriesNoMedia() throws {
        let request = try ClipFinderAI.makeRequest(timeline: "[00:00:01] \"hi\"", section: ClipRange(start: 0, end: 600), duration: 600, model: "test/model", apiKey: "unit-key")
        XCTAssertEqual(request.url?.host, "openrouter.ai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-key")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("json_schema")); XCTAssertTrue(body.contains("test\\/model")); XCTAssertFalse(body.contains("unit-key"))
        XCTAssertTrue(body.contains("Recording length: 00:10:00"))
        let section = try ClipFinderAI.makeRequest(timeline: "", section: ClipRange(start: 600, end: 1200), duration: 7200, model: "m", apiKey: "k")
        XCTAssertTrue(String(data: section.httpBody!, encoding: .utf8)!.contains("SECTION"))
    }

    func testPicksAreClampedScoredAndGated() throws {
        let content = "```json\n{\"clips\":[\(clip("00:01:00", "00:01:25")),\(clip("00:02:00", "00:02:02", title: "Too short")),\(clip("00:03:00", "00:03:25", title: "Weak", ratings: 3)),\(clip("00:04:00", "00:06:00", title: "Too long")),\(clip("bad", "00:01:00", title: "Bad time"))]}\n```"
        let picks = try ClipFinderAI.picks(from: content, section: ClipRange(start: 0, end: 600), duration: 600)
        XCTAssertEqual(picks.map(\.title), ["Missed the easiest shot", "Too long"])
        XCTAssertEqual(picks[0].start, 60); XCTAssertEqual(picks[0].end, 85); XCTAssertEqual(picks[0].score, 82, "8/10 ratings plus the 18–32 second bonus")
        XCTAssertEqual(picks[1].end - picks[1].start, 60, "Long picks are trimmed to a minute")
        XCTAssertEqual(picks[0].hook, "Wait for the reload"); XCTAssertEqual(picks[0].why, "clean payoff")
        XCTAssertThrowsError(try ClipFinderAI.picks(from: "not json", section: ClipRange(start: 0, end: 600), duration: 600))
    }

    func testRankingDropsOverlapsKeepingTheBetterPick() {
        let picks = [AIClipPick(start: 0, end: 20, title: "a", hook: "", reason: "", score: 70), AIClipPick(start: 5, end: 25, title: "b", hook: "", reason: "", score: 90),
                     AIClipPick(start: 18, end: 40, title: "c", hook: "", reason: "", score: 60)]
        XCTAssertEqual(ClipFinderAI.rank(picks).map(\.title), ["b", "c"], "Slight overlaps both stay; mostly-overlapping ones collapse")
    }

    func testFindSendsEachSectionAndReturnsRankedPicks() async throws {
        PlanStub.status = 200; PlanStub.bodies = []
        PlanStub.content = "{\"clips\":[\(clip("00:01:00", "00:01:25"))]}"
        let spoken = transcript([(60, 62, "what was that"), (5000, 5002, "later on")])
        let picks = try await ClipFinderAI.find(transcript: spoken, signals: [], duration: 7200, model: "test/model", apiKey: "k", session: session())
        XCTAssertEqual(PlanStub.bodies.count, ClipFinderAI.sections(duration: 7200).count)
        XCTAssertEqual(picks.count, 1, "The same pick from overlapping sections collapses")
    }

    func testFindStopsOnAuthenticationFailure() async {
        PlanStub.status = 401; defer { PlanStub.status = 200 }
        do {
            _ = try await ClipFinderAI.find(transcript: transcript([(1, 2, "hi")]), signals: [], duration: 600, model: "m", apiKey: "k", session: session())
            XCTFail("Accepted a rejected key")
        } catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
        do {
            _ = try await ClipFinderAI.find(transcript: transcript([]), signals: [], duration: 600, model: "m", apiKey: "k", session: session())
            XCTFail("Sent an empty transcript")
        } catch {}
    }

    func testAIPicksLeadAndMeasuredMomentsFillAround() {
        var settings = AutoClipSettings(); settings.visionEnabled = false; settings.requireBoth = false; settings.maxClips = 5
        let evidence = [ClipEvidence(time: 15, signal: .audio, strength: 0.8, detail: "loud"), ClipEvidence(time: 100, signal: .audio, strength: 0.8, detail: "loud")]
        let pick = AIClipPick(start: 10, end: 30, title: "The reload that never came", hook: "One bullet left", reason: "laughing", why: "clean payoff", score: 82)
        let moments = AutoClipRules.candidates(evidence: evidence, duration: 200, settings: settings, picks: [pick])
        XCTAssertEqual(moments.count, 2, "The measured moment inside the AI pick is dropped")
        XCTAssertTrue(moments[0].pickedByAI); XCTAssertEqual(moments[0].title, "The reload that never came")
        XCTAssertEqual(moments[0].hook, "One bullet left"); XCTAssertEqual(moments[0].reason, "laughing clean payoff")
        XCTAssertTrue(moments[0].evidence.contains { $0.signal == .audio }, "Measured signals inside the pick stay as evidence")
        XCTAssertFalse(moments[1].pickedByAI); XCTAssertEqual(moments[1].title, "Big reaction")
        XCTAssertTrue(moments[0].id.hasPrefix("ai-"))
    }

    // MARK: Vision and copy

    func testFrameTimesFavourMarkersAndPeaksThenSweep() {
        var signals = [ClipEvidence(time: 500, signal: .marker, detail: "mine")]
        signals += (0..<40).map { ClipEvidence(time: 1000 + Double($0) * 2, signal: .audio, strength: Double($0) / 40, detail: "") }
        signals.append(ClipEvidence(time: 2000, signal: .motion, strength: 0.9, detail: ""))
        let spoken = transcript([(3000, 3002, "clip that right now")])
        let times = ClipVisionAI.frameTimes(signals: signals, transcript: spoken, duration: 3600, budget: 20)
        XCTAssertEqual(times.count, 20); XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(times.contains(500)); XCTAssertTrue(times.contains(2997), "A frame just before \"clip that\"")
        XCTAssertTrue(times.contains(2000))
        XCTAssertTrue(times.allSatisfy { $0 >= 0 && $0 < 3600 })
        XCTAssertGreaterThan(times.filter { $0 > 3100 }.count, 0, "Part of the budget sweeps the whole stream")
        XCTAssertTrue(ClipVisionAI.frameTimes(signals: [], transcript: nil, duration: 0, budget: 10).isEmpty)
    }

    func testVisionRequestCarriesFramesAndNotesMapToTimes() throws {
        let request = try ClipVisionAI.makeRequest(frames: [(12, Data([1, 2, 3])), (40, Data([4]))], model: "vision/model", apiKey: "k")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("image_url")); XCTAssertTrue(body.contains("data:image\\/jpeg;base64,AQID")); XCTAssertTrue(body.contains("Frame 2 at 00:00:40"))
        let reply = "{\"frames\":[{\"index\":2,\"activity\":\"Gameplay\",\"description\":\"a close fight\",\"intensity\":3},{\"index\":1,\"activity\":\"dancing\",\"description\":\"lobby\",\"intensity\":0.1},{\"index\":9,\"activity\":\"menu\",\"description\":\"x\",\"intensity\":0}]}"
        let notes = try ClipVisionAI.notes(from: reply, times: [12, 40])
        XCTAssertEqual(notes.map(\.time), [40, 12]); XCTAssertEqual(notes[0].activity, "gameplay"); XCTAssertEqual(notes[0].intensity, 1)
        XCTAssertEqual(notes[1].activity, "other", "Unknown activities become other")
        let line = ClipFinderAI.timeline(transcript: transcript([]), signals: [], notes: notes, in: ClipRange(start: 0, end: 60))
        XCTAssertTrue(line.contains("[00:00:40] (on-screen: gameplay — a close fight, intensity 1.00)"))
    }

    func testDescribeSendsRealFramesFromTheRecording() async throws {
        PlanStub.status = 200; PlanStub.bodies = []
        PlanStub.visionContent = "{\"frames\":[{\"index\":1,\"activity\":\"gameplay\",\"description\":\"busy scene\",\"intensity\":0.7},{\"index\":2,\"activity\":\"menu\",\"description\":\"quiet\",\"intensity\":0.1}]}"
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        let notes = try await ClipVisionAI.describe(media: media, times: [1, 5, 9], model: "vision/model", apiKey: "k", session: session())
        XCTAssertEqual(PlanStub.bodies.count, 1, "Up to six frames share a request")
        XCTAssertEqual(String(decoding: PlanStub.bodies[0], as: UTF8.self).components(separatedBy: "base64,").count - 1, 3)
        XCTAssertEqual(notes.map(\.time), [1, 5])
    }

    func testCopyPassRewritesTitlesKeepsDraftsWhenItCannot() async throws {
        let spoken = transcript([(10, 14, "I cannot believe that worked, he had no idea I was there"), (40, 41, "ok")])
        let picks = [AIClipPick(start: 10, end: 30, title: "Draft one", hook: "Draft hook", reason: "", score: 80), AIClipPick(start: 40, end: 50, title: "Quiet", hook: "", reason: "", score: 70)]
        PlanStub.copyStatus = 200; PlanStub.bodies = []
        PlanStub.copyContent = "{\"title\":\"He never heard me coming\",\"hook\":\"He had no idea\",\"hookOptions\":[\"He had no idea\",\"One flank, no witnesses\",\" \"]}"
        let result = try await ClipCopyAI.polish(picks, transcript: spoken, signals: [], model: "copy/model", apiKey: "k", session: session())
        XCTAssertEqual(result.polished, 1); XCTAssertEqual(PlanStub.bodies.count, 1, "A clip with almost nothing said isn't sent")
        XCTAssertEqual(result.picks[0].title, "He never heard me coming"); XCTAssertEqual(result.picks[0].hook, "He had no idea")
        XCTAssertEqual(result.picks[0].hookOptions, ["One flank, no witnesses"], "Blank and duplicate options are dropped")
        XCTAssertEqual(result.picks[1].title, "Quiet")
        let body = String(decoding: PlanStub.bodies[0], as: UTF8.self)
        XCTAssertTrue(body.contains("Draft title: Draft one")); XCTAssertTrue(body.contains("I cannot believe"))

        PlanStub.copyContent = "not json"
        let unreadable = try await ClipCopyAI.polish(picks, transcript: spoken, signals: [], model: "copy/model", apiKey: "k", session: session())
        XCTAssertEqual(unreadable.polished, 0); XCTAssertEqual(unreadable.picks, picks)
        PlanStub.copyStatus = 402; defer { PlanStub.copyStatus = 200 }
        do { _ = try await ClipCopyAI.polish(picks, transcript: spoken, signals: [], model: "copy/model", apiKey: "k", session: session()); XCTFail("Ignored missing credits") }
        catch { XCTAssertTrue(error.localizedDescription.contains("credits")) }
    }

    func testCopyHookOptionsReachTheIdeasMenu() {
        let pick = AIClipPick(start: 10, end: 30, title: "t", hook: "Main hook", reason: "", score: 80, hookOptions: ["Second", "Third"])
        let moment = AutoClipRules.candidates(evidence: [], duration: 60, settings: AutoClipSettings(), picks: [pick])[0]
        XCTAssertEqual(Array(HookIdeas.suggestions(for: moment).prefix(3)), ["Main hook", "Second", "Third"])
    }

    func testFramesCacheRoundTrip() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        let notes = ScreenNotes(model: "vision/model", budget: 120, notes: [ScreenNote(time: 3, activity: "gameplay", description: "fight", intensity: 0.5)])
        try ScreenNotesCache.save(notes, for: media, root: root)
        XCTAssertEqual(ScreenNotesCache.load(for: media, root: root), notes)
    }
}
