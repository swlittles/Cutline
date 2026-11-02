import XCTest
@testable import CutlineCore

/// Answers like the Claude Messages API: a content array of blocks and a stop reason.
private final class ClaudeStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var text = "{\"clips\":[]}"
    nonisolated(unsafe) static var stopReason = "end_turn"
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
            stream.close(); Self.bodies.append(data)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let payload: [String: Any] = Self.status == 200
            ? ["type": "message", "role": "assistant", "stop_reason": Self.stopReason,
               "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": Self.text]]]
            : ["type": "error", "error": ["type": "invalid_request_error", "message": "model: unknown-model"]]
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClaudeProviderTests: XCTestCase {
    override func setUp() { ClaudeStub.status = 200; ClaudeStub.stopReason = "end_turn"; ClaudeStub.requests = []; ClaudeStub.bodies = [] }
    func session() -> URLSession { let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ClaudeStub.self]; return URLSession(configuration: configuration) }
    func body(_ request: URLRequest) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]) }

    func testClaudeRequestUsesTheMessagesAPIWithStructuredOutput() throws {
        let request = try ClipFinderAI.makeRequest(timeline: "[00:00:01] \"hi\"", section: ClipRange(start: 0, end: 600), duration: 600, model: "claude-opus-5-5", apiKey: "sk-test", provider: .claude)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The key never goes to OpenRouter's header")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(json["fallbacks"] as? String, "default")
        XCTAssertGreaterThanOrEqual(json["max_tokens"] as? Int ?? 0, 16000, "Room for thinking as well as the answer")
        XCTAssertTrue((json["system"] as? String)?.contains("short clips") == true || (json["system"] as? String)?.isEmpty == false)
        XCTAssertNil(json["response_format"]); XCTAssertNil(json["provider"]); XCTAssertNil(json["temperature"])
        let output = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["schema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages[0]["role"] as? String, "user")
    }

    func testOlderClaudeModelsGetNoEffortOrFallback() throws {
        let request = try ClipCopyAI.makeRequest(AIClipPick(start: 0, end: 10, title: "t", hook: "h", reason: "", score: 70), timeline: "", model: "claude-haiku-4-5", apiKey: "k", provider: .claude)
        let json = try body(request)
        XCTAssertNil((json["output_config"] as? [String: Any])?["effort"]); XCTAssertNil(json["fallbacks"])
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testClaudeFramesAreImageBlocks() throws {
        let request = try ClipVisionAI.makeRequest(frames: [(12, Data([1, 2, 3]))], model: "claude-sonnet-5-5", apiKey: "k", provider: .claude)
        let messages = try XCTUnwrap(body(request)["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.first { $0["type"] as? String == "image" })
        let source = try XCTUnwrap(image["source"] as? [String: String])
        XCTAssertEqual(source, ["type": "base64", "media_type": "image/jpeg", "data": "AQID"])
        XCTAssertFalse(content.contains { $0["type"] as? String == "image_url" })
    }

    func testClaudeRepliesAreReadFromTextBlocks() async throws {
        let scores = ["hook", "payoff", "arousal", "pacing", "clarity", "novelty", "strangerRelevance", "commentability"].map { "\"\($0)\":8" }.joined(separator: ",")
        ClaudeStub.text = "{\"clips\":[{\"start\":\"00:00:10\",\"end\":\"00:00:34\",\"title\":\"Missed the easiest shot\",\"hook\":\"Wait for it\",\"reason\":\"laughing\",\"viralityReason\":\"payoff\",\"scores\":{\(scores)}}]}"
        let transcript = StreamTranscript(audioTrack: 0, engine: "test", segments: [TranscriptSegment(start: 12, end: 14, text: "how did I miss that")])
        let picks = try await ClipFinderAI.find(transcript: transcript, signals: [], duration: 600, model: "claude-opus-5-5", apiKey: "k", provider: .claude, session: session())
        XCTAssertEqual(picks.map(\.title), ["Missed the easiest shot"])
        XCTAssertEqual(ClaudeStub.requests.first?.url?.host, "api.anthropic.com")
    }

    func testClaudeFailuresSayWhatToFix() async throws {
        let transcript = StreamTranscript(audioTrack: 0, engine: "test", segments: [TranscriptSegment(start: 1, end: 2, text: "hello there")])
        ClaudeStub.status = 400
        do { _ = try await ClipFinderAI.find(transcript: transcript, signals: [], duration: 600, model: "unknown-model", apiKey: "k", provider: .claude, session: session()); XCTFail("Accepted HTTP 400") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Claude couldn't run this model")); XCTAssertTrue(error.localizedDescription.contains("unknown-model"), "The API's own message is shown") }
        XCTAssertEqual(ClaudeStub.requests.count, 1, "A bad model isn't retried")
        ClaudeStub.status = 200; ClaudeStub.stopReason = "refusal"; ClaudeStub.text = ""
        XCTAssertThrowsError(try AICall.content(of: Data("{\"stop_reason\":\"refusal\",\"content\":[]}".utf8), provider: .claude)) { error in
            XCTAssertEqual((error as? AICall.Failure)?.fatal, false, "A refusal skips this request without stopping the others")
        }
    }

    func testEditingAssistantWorksWithClaude() async throws {
        var project = EditProject()
        let media = MediaItem(url: URL(fileURLWithPath: "/private/gameplay.mp4"), duration: 60)
        project.media = [media]; project.clips = [TimelineClip(mediaID: media.id, sourceOut: 60)]
        project.generateCaptions(from: SourceTranscript(mediaID: media.id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 1, end: 4, text: "That was an amazing team fight")]))
        ClaudeStub.text = "{\"summary\":\"One fight\",\"highlights\":[{\"start\":0,\"end\":10,\"title\":\"Team fight\",\"reason\":\"Excited\",\"score\":90}],\"titles\":[],\"captionEdits\":[]}"
        let proposal = try await EditingAssistant.request(project: project, prompt: "Highlights", model: "claude-opus-5-5", apiKey: "k", provider: .claude, session: session())
        XCTAssertEqual(proposal.highlights.map(\.title), ["Team fight"])
        ClaudeStub.status = 401
        do { _ = try await EditingAssistant.request(project: project, prompt: "Highlights", model: "claude-opus-5-5", apiKey: "k", provider: .claude, session: session()); XCTFail("Accepted HTTP 401") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Claude request failed")); XCTAssertTrue(error.localizedDescription.contains("API key")) }
    }

    func testEachProviderKeepsItsOwnKey() throws {
        let environment = AppEnvironment(bundleIdentifier: "studio.cutline.editor")
        XCTAssertEqual(environment.claudeCredentialService, "studio.cutline.anthropic")
        XCTAssertEqual(AppEnvironment(bundleIdentifier: nil).claudeCredentialService, "studio.cutline.dev.anthropic")
        XCTAssertNotEqual(AIProvider.openRouter.testCredentialFile, AIProvider.claude.testCredentialFile)
        XCTAssertEqual(AIProvider.claude.defaultModel, "claude-opus-5-5")
    }
}

final class SoundLibraryTests: XCTestCase {
    func testPacksImportWithCategoriesAndNamesAndSoundsCanBeRemoved() async throws {
        let root = try Fixtures.temporary(), pack = try Fixtures.temporary()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: pack) }
        for folder in ["impact", "Big Risers", "_originals"] { try FileManager.default.createDirectory(at: pack.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let audio = Fixtures.url("music.m4a")
        try FileManager.default.copyItem(at: audio, to: pack.appendingPathComponent("impact/vine-boom.m4a"))
        try FileManager.default.copyItem(at: audio, to: pack.appendingPathComponent("Big Risers/slow_build.m4a"))
        try FileManager.default.copyItem(at: audio, to: pack.appendingPathComponent("_originals/vine-boom.m4a"))
        try FileManager.default.copyItem(at: audio, to: pack.appendingPathComponent("loose.m4a"))
        try Data("not audio".utf8).write(to: pack.appendingPathComponent("impact/notes.txt"))
        try Data("{\"impact/vine-boom.m4a\":{\"label\":\"Vine boom\",\"useWhen\":\"a punchline\"}}".utf8).write(to: pack.appendingPathComponent("sounds.json"))

        XCTAssertEqual(try SoundLibrary.importPack(pack, root: root), 3, "Working folders that start with _ are skipped")
        let sounds = await SoundLibrary.sounds(root: root)
        XCTAssertEqual(sounds.map(\.id), ["impact/vine-boom.m4a", "other/loose.m4a", "big-risers/slow_build.m4a"], "Known categories first, then others")
        XCTAssertEqual(sounds.map(\.name), ["Vine boom", "Loose", "Slow build"])
        XCTAssertTrue(sounds.allSatisfy { $0.duration > 0 })
        XCTAssertEqual(try SoundLibrary.importPack(pack, root: root), 3, "Importing again replaces rather than duplicates")
        let reimported = await SoundLibrary.sounds(root: root)
        XCTAssertEqual(reimported.count, 3)

        XCTAssertEqual(try SoundLibrary.add([audio, audio], category: "Whoosh", root: root), 2)
        let whooshes = await SoundLibrary.sounds(root: root).filter { $0.category == "whoosh" }
        XCTAssertEqual(whooshes.map(\.url.lastPathComponent).sorted(), ["music 2.m4a", "music.m4a"], "Names never collide")
        XCTAssertThrowsError(try SoundLibrary.add([pack.appendingPathComponent("impact/notes.txt")], category: "pop", root: root))

        try SoundLibrary.remove(sounds[0], root: root)
        let remaining = await SoundLibrary.sounds(root: root)
        XCTAssertFalse(remaining.contains { $0.id == "impact/vine-boom.m4a" })
        let outside = SoundEffect(id: "x/y.m4a", name: "y", category: "x", url: audio, duration: 1)
        XCTAssertThrowsError(try SoundLibrary.remove(outside, root: root), "Never deletes outside the library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testMomentSoundsAreMixedIntoTheExportedShort() throws {
        let media = MediaItem(url: Fixtures.url("autoclip.mp4"), duration: 12)
        let report = AutoClipReport(media: media, settings: AutoClipSettings(), candidates: [], evidence: [])
        let candidate = AutoClipCandidate(id: "m1", start: 2, end: 8, score: 50, evidence: [])
        let sound = SoundEffect(id: "impact/boom.m4a", name: "Boom", category: "impact", url: Fixtures.url("music.m4a"), duration: 1.5)
        let placed = [AudioClip(sound: sound, start: 1), AudioClip(sound: sound, start: 30)]
        let project = try AutoClipBatch.clipProject(candidate, report: report, options: ProjectSettings(), hook: nil, captions: nil, sounds: placed)
        XCTAssertEqual(project.music?.count, 1, "A sound past the end of a trimmed clip is left out")
        XCTAssertEqual(project.music?.first?.start, 1); XCTAssertEqual(project.music?.first?.name, "Boom"); XCTAssertEqual(project.music?.first?.volume, 0.8)
        XCTAssertNil(try AutoClipBatch.clipProject(candidate, report: report, options: ProjectSettings(), hook: nil, captions: nil).music)
    }
}
