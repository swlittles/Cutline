import XCTest
@testable import CutlineCore

private final class StubProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AssistantTests: XCTestCase {
    func project() -> EditProject {
        var project = EditProject()
        let media = MediaItem(url: URL(fileURLWithPath: "/private/gameplay.mp4"), duration: 60)
        project.media = [media]; project.clips = [TimelineClip(mediaID: media.id, sourceOut: 60)]
        project.generateCaptions(from: SourceTranscript(mediaID: media.id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 1, end: 4, text: "That was an amazing team fight")]))
        return project
    }
    func session() -> URLSession { let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]; return URLSession(configuration: configuration) }
    func testStructuredRequestContainsOnlyTranscriptAndPrompt() throws {
        let project = project()
        let request = try EditingAssistant.makeRequest(transcript: EditingAssistant.transcriptChunks(for: project)[0], duration: project.duration, prompt: "Find highlights", model: "test/model", apiKey: "unit-test-key")
        XCTAssertEqual(request.url?.host, "openrouter.ai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-key")
        let text = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertFalse(text.contains("/private/gameplay.mp4")); XCTAssertFalse(text.contains("unit-test-key"))
        XCTAssertTrue(text.contains("json_schema")); XCTAssertTrue(text.contains("require_parameters"))
    }
    func testLiveRequestPathWithMockedProvider() async throws {
        let content = "{\"summary\":\"A good moment\",\"highlights\":[{\"start\":0,\"end\":10,\"title\":\"Team fight\",\"reason\":\"Excited commentary\",\"score\":90}],\"titles\":[\"The comeback\"],\"captionEdits\":[]}"
        StubProtocol.status = 200
        StubProtocol.payload = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let result = try await EditingAssistant.request(project: project(), prompt: "Highlights", model: "test/model", apiKey: "test", session: session())
        XCTAssertEqual(result.highlights.count, 1); XCTAssertEqual(result.highlights[0].end, 10)
    }
    func testProviderAuthenticationFailureIsActionable() async {
        StubProtocol.status = 401; StubProtocol.payload = Data()
        do { _ = try await EditingAssistant.request(project: project(), prompt: "Highlights", model: "test/model", apiKey: "test", session: session()); XCTFail("Must reject authentication failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
    }
    func testOutOfRangeAndUnknownCaptionEditsRejected() throws {
        let bad = "{\"summary\":\"No\",\"highlights\":[{\"start\":0,\"end\":100,\"title\":\"Bad\",\"reason\":\"Bad\",\"score\":10}],\"titles\":[],\"captionEdits\":[]}"
        let proposal = try JSONDecoder().decode(AIEditProposal.self, from: Data(bad.utf8))
        XCTAssertThrowsError(try proposal.validated(for: project()))
        let unknown = "{\"summary\":\"No\",\"highlights\":[],\"titles\":[],\"captionEdits\":[{\"id\":\"unknown\",\"text\":\"Changed\"}]}"
        XCTAssertThrowsError(try JSONDecoder().decode(AIEditProposal.self, from: Data(unknown.utf8)).validated(for: project()))
    }
    func testChunkingPreservesEveryCaptionExactlyOnce() {
        var project = project()
        let clip = project.clips[0]
        project.captionTrack?.cues = (0..<200).map { CaptionCue(clipID: clip.id, sourceStart: Double($0) / 10, sourceEnd: Double($0 + 1) / 10, text: "Sentence \($0)") }
        let chunks = EditingAssistant.transcriptChunks(for: project, limit: 1000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined().components(separatedBy: "id=").count - 1, 200)
    }
}

extension AssistantTests {
    func testHTTPFailuresIncludeUsefulRecoveryHints() async {
        for (status, hint) in [(402,"credits"),(403,"API key"),(429,"Rate limit"),(500,"model ID")] {
            StubProtocol.status = status; StubProtocol.payload = Data()
            do { _ = try await EditingAssistant.request(project: project(), prompt: "Highlights", model: "test/model", apiKey: "test", session: session()); XCTFail("Accepted HTTP \(status)") }
            catch { XCTAssertTrue(error.localizedDescription.contains(hint)) }
        }
    }
    func testEmptyChoicesNullContentAndMalformedEnvelopesAreRejected() async {
        for payload in ["{}", "not JSON", "{\"choices\":[]}", "{\"choices\":[{\"message\":{\"content\":null}}]}"] {
            StubProtocol.status = 200; StubProtocol.payload = Data(payload.utf8)
            do { _ = try await EditingAssistant.request(project: project(), prompt: "Highlights", model: "test/model", apiKey: "test", session: session()); XCTFail("Accepted invalid envelope") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    func testMissingCaptionDataRejectsBeforeRequest() async {
        var empty = project(); empty.captionTrack = nil
        do { _ = try await EditingAssistant.request(project: empty, prompt: "Highlights", model: "test/model", apiKey: "test", session: session()); XCTFail("Expected missing transcript error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("captions first")) }
    }
    func testBlankInstructionOrModelIsRejected() async {
        for (prompt, model) in [(" \n", "test/model"),("Highlights", "  ")] {
            do { _ = try await EditingAssistant.request(project: project(), prompt: prompt, model: model, apiKey: "test", session: session()); XCTFail("Accepted blank input") }
            catch { XCTAssertTrue(error.localizedDescription.contains("editing instruction")) }
        }
    }
    func testDuplicateCaptionEditsAndWhitespaceAreRejected() throws {
        let p = project()
        // IDs are taken from the same snapshot being validated.
        let validID = p.captionTrack!.cues[0].id.uuidString
        let edit = AICaptionEdit(id: validID, text: "Edited")
        XCTAssertThrowsError(try AIEditProposal(summary: "", highlights: [], titles: [], captionEdits: [edit,edit]).validated(for: p))
        XCTAssertThrowsError(try AIEditProposal(summary: "", highlights: [], titles: [], captionEdits: [AICaptionEdit(id: validID, text: " \n")]).validated(for: p))
    }
    func testProposalSizeLimitsAreEnforced() {
        let p = project()
        for proposal in [AIEditProposal(summary: String(repeating: "a", count: 12001), highlights: [], titles: [], captionEdits: []), AIEditProposal(summary: "", highlights: [], titles: Array(repeating: "Title", count: 31), captionEdits: []), AIEditProposal(summary: "", highlights: [], titles: [String(repeating: "a", count: 501)], captionEdits: [])] { XCTAssertThrowsError(try proposal.validated(for: p)) }
    }
    func testHighlightScoreAndNonfiniteBoundsAreRejected() {
        for h in [AIHighlight(start: 0, end: 5, title: "", reason: "", score: 101), AIHighlight(start: .nan, end: 5, title: "", reason: "", score: 50), AIHighlight(start: 5, end: 5, title: "", reason: "", score: 50), AIHighlight(start: -1, end: 5, title: "", reason: "", score: 50)] {
            XCTAssertThrowsError(try AIEditProposal(summary: "", highlights: [h], titles: [], captionEdits: []).validated(for: project()))
        }
    }
    func testOverlappingHighlightsAndTitlesAreDeduplicated() async throws {
        let proposal = AIEditProposal(summary: "Summary", highlights: [AIHighlight(start: 1, end: 10, title: "First", reason: "", score: 20), AIHighlight(start: 2, end: 10, title: "Best", reason: "", score: 90), AIHighlight(start: 20, end: 30, title: "Other", reason: "", score: 50)], titles: ["Same","Same","Other"], captionEdits: [])
        let content = String(data: try JSONEncoder().encode(proposal), encoding: .utf8)!
        StubProtocol.status = 200; StubProtocol.payload = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let result = try await EditingAssistant.request(project: project(), prompt: "Highlights", model: "test/model", apiKey: "test", session: session())
        XCTAssertEqual(result.highlights.map(\.title), ["Best","Other"]); XCTAssertEqual(result.titles, ["Same","Other"])
    }
    func testCancelledRequestCannotReturnProposal() async {
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await EditingAssistant.request(project: project(), prompt: "Highlights", model: "test/model", apiKey: "test", session: session()) }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
