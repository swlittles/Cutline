import XCTest
@testable import CutlineCore

final class TranscriptEditTests: XCTestCase {
    func project() -> EditProject {
        let media = MediaItem(url: URL(fileURLWithPath: "/tmp/test.mp4"), duration: 20)
        var project = EditProject(); project.media = [media]
        var clip = TimelineClip(mediaID: media.id, sourceOut: 20)
        clip.adjustments = ClipAdjustments(); clip.adjustments?.speed = 2
        project.clips = [clip]
        project.generateCaptions(from: SourceTranscript(mediaID: media.id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 0, end: 2, text: "First"), TranscriptSegment(start: 8, end: 12, text: "Middle"), TranscriptSegment(start: 16, end: 20, text: "Last")]))
        project.overlays = [OverlayClip(mediaID: media.id, start: 0, duration: 10)]
        project.music = [AudioClip(url: media.url, start: 0, duration: 10)]
        project.markers = [HighlightMarker(clipID: clip.id, sourceTime: 4, label: "Removed"), HighlightMarker(clipID: clip.id, sourceTime: 18, label: "Kept")]
        return project
    }
    func testRippleCutsPreserveEveryTrackAndSpeed() throws {
        var project = project()
        try project.removeTimelineRanges([TimelineRange(start: 1, end: 4), TimelineRange(start: 6, end: 8)])
        XCTAssertEqual(project.duration, 5, accuracy: 0.001)
        XCTAssertEqual(project.clips.map(\.sourceIn), [0,8,16]); XCTAssertEqual(project.clips.map(\.sourceOut), [2,12,20])
        XCTAssertEqual(project.clips.map(\.speed), [2,2,2])
        XCTAssertEqual(project.projectedCaptions().map(\.start), [0,1,3])
        XCTAssertEqual(project.overlays?.map(\.start), [0,1,3]); XCTAssertEqual(project.overlays?.map(\.sourceIn), [0,4,8])
        XCTAssertEqual(project.music?.map(\.start), [0,1,3]); XCTAssertEqual(project.music?.map(\.sourceIn), [0,4,8])
        XCTAssertEqual(project.markers?.map(\.label), ["Kept"])
        XCTAssertEqual(Set(project.clips.map(\.id)).count, 3)
        XCTAssertEqual(Set(project.overlays!.map(\.id)).count, 3)
        try project.validate()
    }
    func testGapReviewIncludesPaddingAndMergesOverlappingCaptions() {
        var project = project()
        let gaps = project.speechGaps(minimum: 1, padding: 0.2)
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].start, 1.2, accuracy: 0.001); XCTAssertEqual(gaps[0].end, 3.8, accuracy: 0.001)
        project.captionTrack?.cues.append(CaptionCue(clipID: project.clips[0].id, sourceStart: 0, sourceEnd: 20, text: "Overlapping"))
        XCTAssertTrue(project.speechGaps().isEmpty)
    }
    func testInvalidOrEntireTimelineCutsDoNotMutateProject() {
        var project = project(); let original = project
        XCTAssertThrowsError(try project.keepTimelineRanges([TimelineRange(start: 0, end: 4),TimelineRange(start: 3, end: 8)]))
        XCTAssertEqual(project, original)
        XCTAssertThrowsError(try project.removeTimelineRanges([TimelineRange(start: 0, end: 10)]))
        XCTAssertEqual(project, original)
    }
    func testOverlappingCutsMergeBeforeApplying() throws {
        var project = project()
        try project.removeTimelineRanges([TimelineRange(start: 1, end: 3), TimelineRange(start: 2, end: 4)])
        XCTAssertEqual(project.duration, 7, accuracy: 0.001)
    }
}
