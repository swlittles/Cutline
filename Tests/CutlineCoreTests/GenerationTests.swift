import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CutlineCore

private final class GenerationStub: URLProtocol {
    static var payload = Data()
    static var status = 200
    static var content: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: request.url?.path.hasSuffix("/content") == true ? (Self.content ?? Data()) : Self.payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GenerationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        GenerationStub.content = nil
        setenv("CUTLINE_TEST_ROOT", root.path, 1)
        guard LocalTools.testingRoot?.path == root.path else { throw XCTSkip("Test isolation requires a Debug build") }
        XCTAssertEqual(LocalTools.support.path, root.path)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root); unsetenv("CUTLINE_TEST_ROOT")
    }
    func session() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [GenerationStub.self]; return URLSession(configuration: c) }
    func model() throws -> GenerationModel {
        try JSONDecoder().decode(GenerationModel.self, from: Data("""
        {"id":"test/model","name":"Test","supported_parameters":{"n":{"type":"range","min":1,"max":1}},"supported_durations":[4,8],"supported_resolutions":["720p"],"supported_aspect_ratios":["16:9"]}
        """.utf8))
    }
    func testCapabilitiesAndPrivateRequestBody() throws {
        let model = try model()
        let request = try MediaGeneration.request(kind: .video, model: model, prompt: "An intro", ratio: "16:9", resolution: "720p", duration: 4, apiKey: "secret-test")
        XCTAssertEqual(request.url?.path, "/api/v1/videos")
        XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains("secret-test"))
        XCTAssertThrowsError(try MediaGeneration.request(kind: .video, model: model, prompt: "An intro", ratio: "1:1", resolution: "720p", duration: 4, apiKey: "test"))
        XCTAssertThrowsError(try MediaGeneration.request(kind: .video, model: model, prompt: "An intro", ratio: "16:9", resolution: "720p", duration: 60, apiKey: "test"))
    }
    func testJobIDsCannotRedirectCredentialsOrTraversePaths() throws {
        XCTAssertEqual(try MediaGeneration.jobURL("job_test-123").host, "openrouter.ai")
        for id in ["../chat", "https://example.com", "foo?key=bar", "foo/bar", "", "ümlaut"] { XCTAssertThrowsError(try MediaGeneration.jobURL(id)) }
    }
    func testImageGenerationDecodesAndPersistsRaster() async throws {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let bytes = NSMutableData(); let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        GenerationStub.status = 200
        GenerationStub.payload = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": (bytes as Data).base64EncodedString()]], "usage": ["cost": 0.03]])
        let record = GenerationRecord(kind: .image, model: "test/model", prompt: "Unit test")
        defer { try? FileManager.default.removeItem(at: record.directory) }
        let request = try MediaGeneration.request(kind: .image, model: model(), prompt: "Unit test", ratio: "", resolution: "", duration: 4, apiKey: "test")
        let result = try await MediaGeneration.image(request: request, record: record, session: session())
        XCTAssertEqual(result.status, "completed"); XCTAssertEqual(result.cost, 0.03)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.assetURL!.path))
        XCTAssertTrue(GenerationRecord.saved().contains { $0.id == record.id })
        XCTAssertThrowsError(try MediaGeneration.normalizedPNG(Data("<svg></svg>".utf8)))
    }
    func testVideoJobIsDurableBeforePollingAndFailureIsSurfaced() async throws {
        GenerationStub.status = 202; GenerationStub.payload = Data("{\"id\":\"job_test\",\"status\":\"pending\",\"polling_url\":\"https://untrusted.example\"}".utf8)
        let record = GenerationRecord(kind: .video, model: "test/model", prompt: "Unit test")
        defer { try? FileManager.default.removeItem(at: record.directory) }
        let request = try MediaGeneration.request(kind: .video, model: model(), prompt: "Unit test", ratio: "16:9", resolution: "720p", duration: 4, apiKey: "test")
        let result = try await MediaGeneration.submitVideo(request: request, record: record, session: session())
        XCTAssertEqual(GenerationRecord.saved().first { $0.id == record.id }?.remoteID, "job_test")
        GenerationStub.status = 200; GenerationStub.payload = Data("{\"id\":\"job_test\",\"status\":\"failed\"}".utf8)
        do { _ = try await MediaGeneration.pollVideo(result, apiKey: "test", session: session(), interval: 1); XCTFail("Must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("failed")) }
    }
    func testProcessCancellationTerminatesChild() async throws {
        let start = Date()
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}


extension GenerationTests {
    func testCompletedVideoDownloadsInspectsAndPersistsMedia() async throws {
        GenerationStub.status = 200; GenerationStub.payload = Data("{\"id\":\"job_complete\",\"status\":\"completed\",\"usage\":{\"cost\":0.5}}".utf8)
        GenerationStub.content = try Data(contentsOf: Fixtures.directory.appendingPathComponent("gameplay.mp4"))
        var record = GenerationRecord(kind: .video, model: "test/model", prompt: "Completed fixture")
        record.remoteID = "job_complete"
        let result = try await MediaGeneration.pollVideo(record, apiKey: "test", session: session(), interval: 1)
        XCTAssertEqual(result.status, "completed"); XCTAssertEqual(result.cost, 0.5)
        let media = try await CompositionEngine.inspect(XCTUnwrap(result.assetURL))
        XCTAssertEqual(media.duration, 5, accuracy: 0.1)
        XCTAssertEqual(GenerationRecord.saved().first?.assetName, "video.mp4")
    }
}

extension GenerationTests {
    func testDownloadedNonVideoCannotBecomeLibraryAsset() async throws {
        GenerationStub.status = 200; GenerationStub.payload = Data("{\"id\":\"job_bad\",\"status\":\"completed\"}".utf8)
        GenerationStub.content = Data("not a video".utf8)
        var record = GenerationRecord(kind: .video, model: "test/model", prompt: "Invalid result"); record.remoteID = "job_bad"
        do { _ = try await MediaGeneration.pollVideo(record, apiKey: "test", session: session(), interval: 1); XCTFail("Accepted invalid video") } catch {}
        XCTAssertNil(GenerationRecord.saved().first?.assetURL)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: record.directory.path).contains { $0.hasSuffix(".mp4") })
    }
    func testMismatchedProviderJobIDIsRejected() async throws {
        GenerationStub.status = 200; GenerationStub.payload = Data("{\"id\":\"other_job\",\"status\":\"completed\"}".utf8)
        var record = GenerationRecord(kind: .video, model: "test/model", prompt: "Mismatch"); record.remoteID = "job_expected"
        do { _ = try await MediaGeneration.pollVideo(record, apiKey: "test", session: session(), interval: 1); XCTFail("Accepted different job") }
        catch { XCTAssertTrue(error.localizedDescription.contains("different video job")) }
    }
    func testUnknownJobStatusRemainsResumable() async throws {
        GenerationStub.status = 200; GenerationStub.payload = Data("{\"id\":\"job_new\",\"status\":\"new_provider_state\"}".utf8)
        var record = GenerationRecord(kind: .video, model: "test/model", prompt: "Unknown state"); record.remoteID = "job_new"
        do { _ = try await MediaGeneration.pollVideo(record, apiKey: "test", session: session(), interval: 1); XCTFail("Accepted unknown state") }
        catch { XCTAssertTrue(error.localizedDescription.contains("resume later")) }
        XCTAssertEqual(GenerationRecord.saved().first?.remoteID, "job_new")
    }
    func testCatalogFiltersUnsupportedVideoModelsAndSortsNames() async throws {
        GenerationStub.status = 200
        GenerationStub.payload = Data("{\"data\":[{\"id\":\"z\",\"name\":\"Zebra\",\"supported_durations\":[4]},{\"id\":\"a\",\"name\":\"Apple\",\"supported_durations\":[8]},{\"id\":\"no\",\"name\":\"Unsupported\"}]}".utf8)
        let models = try await MediaGeneration.catalog(.video, session: session())
        XCTAssertEqual(models.map(\.id), ["a","z"])
    }
    func testMetadataRejectsPathTraversalAndWrongDirectoryIdentity() throws {
        var record = GenerationRecord(kind: .image, model: "test", prompt: "Metadata")
        record.assetName = "../../sensitive.png"; try record.save(); XCTAssertTrue(GenerationRecord.saved().isEmpty)
        record.assetName = "image.png"; try record.save()
        let badFolder = LocalTools.support.appendingPathComponent("Generated/wrong-directory")
        try FileManager.default.moveItem(at: record.directory, to: badFolder)
        XCTAssertTrue(GenerationRecord.saved().isEmpty)
    }
}
