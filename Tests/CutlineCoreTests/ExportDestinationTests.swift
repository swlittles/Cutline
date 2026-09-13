import XCTest
@testable import CutlineCore

final class ExportDestinationTests: XCTestCase {
    func testSuccessfulRenderAtomicallyReplacesDestination() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("movie.mp4"); try Data("old".utf8).write(to: url)
        try await ExportDestination.write(to: url) { try Data("new".utf8).write(to: $0) }
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["movie.mp4"])
    }
    func testFailedRenderPreservesExistingFileAndCleansTemporary() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("movie.mp4"); try Data("keep".utf8).write(to: url)
        do { try await ExportDestination.write(to: url) { try Data("partial".utf8).write(to: $0); throw EditError.invalid("Failed renderer") }; XCTFail("Expected failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("keep".utf8)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["movie.mp4"])
    }
    func testCancellationAfterRenderingDoesNotReplaceFile() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("movie.mp4"); try Data("keep".utf8).write(to: url)
        let started = expectation(description: "Renderer started")
        let task = Task { try await ExportDestination.write(to: url) { temporary in try Data("partial".utf8).write(to: temporary); started.fulfill(); try await Task.sleep(nanoseconds: 30_000_000_000) } }
        await fulfillment(of: [started], timeout: 2); task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: url), Data("keep".utf8)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["movie.mp4"])
    }
    func testSourceAndSymlinkDestinationsAreRejectedBeforeRendering() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"), link = root.appendingPathComponent("alias.mp4")
        try Data("original".utf8).write(to: source); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for destination in [source,link] {
            do { try await ExportDestination.write(to: destination, protecting: [source]) { _ in XCTFail("Must not render") }; XCTFail("Must reject source overwrite") } catch { XCTAssertTrue(error.localizedDescription.contains("source media")) }
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }
    func testMissingRenderedOutputIsRejected() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        do { try await ExportDestination.write(to: root.appendingPathComponent("movie.mp4")) { _ in }; XCTFail("Expected missing output") } catch { XCTAssertTrue(error.localizedDescription.contains("output file")) }
    }
    func testRemoteDestinationsAreRejected() async {
        do { try await ExportDestination.write(to: URL(string: "https://example.com/video.mp4")!) { _ in XCTFail("Must not render") }; XCTFail("Expected failure") } catch {}
    }
}
