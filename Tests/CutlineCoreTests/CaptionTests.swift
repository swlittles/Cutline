import XCTest
@testable import CutlineCore

final class CaptionTests: XCTestCase {
    func sample() -> EditProject {
        var project = EditProject()
        let media = MediaItem(url: URL(fileURLWithPath: "/tmp/gameplay.mp4"), duration: 120)
        let clip = TimelineClip(mediaID: media.id, sourceIn: 10, sourceOut: 30)
        project.media = [media]; project.clips = [clip]
        project.generateCaptions(from: SourceTranscript(mediaID: media.id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 12, end: 18, text: "Great play"), TranscriptSegment(start: 50, end: 55, text: "Unused source")]))
        return project
    }
    func testCaptionsFollowSplitTrimAndSpeed() throws {
        var project = sample()
        XCTAssertEqual(project.captionTrack?.cues.count, 1, "Unused source captions must not bloat every timeline clip")
        let right = project.split(at: 5)!
        var projected = project.projectedCaptions()
        XCTAssertEqual(projected.map(\.start), [2,5]); XCTAssertEqual(projected.map(\.end), [5,8])
        project.clips[1].adjustments = ClipAdjustments(); project.clips[1].adjustments?.speed = 2
        projected = project.projectedCaptions()
        XCTAssertEqual(projected[1].end, 6.5)
        project.clips[0].sourceIn = 13
        projected = project.projectedCaptions()
        XCTAssertEqual(projected[0].start, 0); XCTAssertEqual(projected[1].start, 2)
        project.removeClip(right)
        try project.validate(); XCTAssertEqual(project.captionTrack?.cues.count, 1)
    }
    func testRangeSelectionRebasesCaptionsAndLayers() throws {
        var project = sample()
        project.overlays = [OverlayClip(mediaID: project.media[0].id, start: 1, duration: 10)]
        project.music = [AudioClip(url: URL(fileURLWithPath: "/tmp/music.wav"), start: 2, duration: 8)]
        try project.keepTimelineRange(start: 4, end: 8)
        XCTAssertEqual(project.duration, 4)
        XCTAssertEqual(project.clips[0].sourceIn, 14)
        XCTAssertEqual(project.projectedCaptions()[0].start, 0)
        XCTAssertEqual(project.projectedCaptions()[0].end, 4)
        XCTAssertEqual(project.overlays?[0].sourceIn, 3)
        XCTAssertEqual(project.music?[0].sourceIn, 2)
        XCTAssertEqual(project.music?[0].start, 0)
    }
    func testSubtitleRoundTripUnicodeMultilineAndHours() throws {
        let text = "1\n01:02:03,450 --> 01:02:05,900\nこんにちは\nGreat play!\n\n2\n01:02:06,000 --> 01:02:07,000\nNext\n"
        let cues = try SubtitleFile.decode(text)
        XCTAssertEqual(cues[0].start, 3723.45, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "こんにちは\nGreat play!")
        let projected = cues.map { ProjectedCaption(id: $0.id, start: $0.start, end: $0.end, text: $0.text) }
        let vtt = SubtitleFile.encode(projected, vtt: true)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        let reread = try SubtitleFile.decode(vtt)
        XCTAssertEqual(reread.map(\.text), cues.map(\.text))
        XCTAssertEqual(reread.map(\.start), cues.map(\.start))
    }
    func testInvalidCaptionsRejected() {
        XCTAssertThrowsError(try SubtitleFile.decode("1\n00:01,000 --> 00:00,500\nNo\n"))
        XCTAssertThrowsError(try SubtitleFile.decode("invalid"))
        var project = sample(); project.captionTrack?.cues[0].clipID = UUID()
        XCTAssertThrowsError(try project.validate())
    }
    func testVersionOneMigration() throws {
        let json = "{\"version\":1,\"name\":\"Old project\",\"format\":\"landscape\",\"media\":[],\"clips\":[]}"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try json.write(to: url, atomically: true, encoding: .utf8)
        let project = try EditProject.read(from: url)
        XCTAssertEqual(project.version, 3); XCTAssertEqual(project.options.fps, 30)
    }
    func testKeyframeInterpolationAndBounds() {
        var adjustments = ClipAdjustments()
        adjustments.keyframes = [TransformKeyframe(sourceTime: 0, zoom: 1, x: 0, y: 0, rotation: 0), TransformKeyframe(sourceTime: 10, zoom: 2, x: 0.5, y: -0.5, rotation: 90)]
        XCTAssertEqual(adjustments.interpolated(at: 5).zoom, 1.5)
        XCTAssertEqual(adjustments.interpolated(at: 5).rotation, 45)
        XCTAssertEqual(adjustments.interpolated(at: 20).zoom, 2)
        XCTAssertEqual(adjustments.interpolated(at: -1).zoom, 1)
        adjustments.smoothKeyframes = true
        XCTAssertLessThan(adjustments.interpolated(at: 2).zoom, 1.2)
    }
    func testMarkersMoveToCorrectSideOfSplit() {
        var project = sample()
        project.markers = [HighlightMarker(clipID: project.clips[0].id, sourceTime: 20, label: "Moment")]
        let right = project.split(at: 5)
        XCTAssertEqual(project.markers?[0].clipID, right)
    }
}
