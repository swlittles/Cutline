import XCTest
@testable import CutlineCore

final class ProjectTests: XCTestCase {
    func sample() -> EditProject {
        var project = EditProject()
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/gameplay.mp4"), duration: 60)
        project.media = [item]
        project.clips = [TimelineClip(mediaID: item.id, sourceIn: 10, sourceOut: 30)]
        return project
    }
    func testSplitPreservesSourceRangeAndDuration() throws {
        var project = sample()
        let id = project.split(at: 8)
        XCTAssertNotNil(id)
        XCTAssertEqual(project.clips.count, 2)
        XCTAssertEqual(project.clips[0].sourceOut, 18)
        XCTAssertEqual(project.clips[1].sourceIn, 18)
        XCTAssertEqual(project.clips[1].sourceOut, 30)
        XCTAssertEqual(project.duration, 20)
        XCTAssertEqual(project.start(of: id!), 8)
        try project.validate()
    }
    func testSplitRejectsBoundariesAndOutsideTimeline() {
        for time in [-1.0, 0, 0.01, 19.99, 20, 40] {
            var project = sample()
            XCTAssertNil(project.split(at: time))
            XCTAssertEqual(project.clips.count, 1)
        }
    }
    func testInvalidSourceRangesAndReferencesRejected() {
        var project = sample(); project.clips[0].sourceOut = 61
        XCTAssertThrowsError(try project.validate())
        project = sample(); project.clips[0].sourceIn = -1
        XCTAssertThrowsError(try project.validate())
        project = sample(); project.media = []
        XCTAssertThrowsError(try project.validate())
        project = sample(); project.clips[0].volume = .nan
        XCTAssertThrowsError(try project.validate())
        project = sample(); project.version = 200
        XCTAssertThrowsError(try project.validate())
    }
    func testProjectRoundTrip() throws {
        var project = sample(); project.format = .portrait; _ = project.split(at: 7)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cutline")
        defer { try? FileManager.default.removeItem(at: url) }
        try project.write(to: url)
        XCTAssertEqual(try EditProject.read(from: url), project)
    }
    func testTimecodes() {
        XCTAssertEqual(timecode(3661.25), "61:01.25")
        XCTAssertEqual(timecode(-2), "00:00.00")
        XCTAssertEqual(timecode(.nan), "00:00.00")
    }
}
