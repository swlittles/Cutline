import XCTest
@testable import CutlineCore

final class ValidationTests: XCTestCase {
    func testDuplicateMediaAndClipIDsRejected() {
        var p = Fixtures.project(); p.media.append(p.media[0]); XCTAssertThrowsError(try p.validate())
        p = Fixtures.project(); p.clips.append(p.clips[0]); XCTAssertThrowsError(try p.validate())
    }
    func testNonFileMediaAndNonfiniteDurationsRejected() {
        for duration in [Double.nan,.infinity,-1,0] { var p = Fixtures.project(); p.media[0].duration = duration; XCTAssertThrowsError(try p.validate()) }
        var p = Fixtures.project(); p.media[0].url = URL(string: "https://example.com/recording.mp4")!; XCTAssertThrowsError(try p.validate())
    }
    func testEveryAdjustmentRejectsNonfiniteInput() {
        let keys: [WritableKeyPath<ClipAdjustments,Double>] = [\.speed,\.zoom,\.x,\.y,\.rotation,\.brightness,\.contrast,\.saturation,\.fadeIn,\.fadeOut]
        for key in keys { for value in [Double.nan,.infinity,-Double.infinity] { var p = Fixtures.project(); var a = ClipAdjustments(); a[keyPath:key] = value; p.clips[0].adjustments = a; XCTAssertThrowsError(try p.validate()) } }
    }
    func testAdjustmentAndOutputBounds() {
        for speed in [0.0,8.1] { var p = Fixtures.project(); p.clips[0].adjustments = ClipAdjustments(); p.clips[0].adjustments?.speed = speed; XCTAssertThrowsError(try p.validate()) }
        var p = Fixtures.project(); p.options.fps = 120; XCTAssertThrowsError(try p.validate()); p.options.fps = 30; p.options.resolution = 480; XCTAssertThrowsError(try p.validate())
    }
    func testOverlayReferencesDurationsAndUniqueIDs() {
        var p = Fixtures.project(); let overlay = OverlayClip(mediaID: p.media[0].id, start: 0, duration: 5)
        p.overlays = [overlay,overlay]; XCTAssertThrowsError(try p.validate())
        p.overlays = [overlay]; p.overlays?[0].sourceIn = 1; XCTAssertThrowsError(try p.validate())
        p.overlays?[0].sourceIn = 0; p.overlays?[0].mediaID = UUID(); XCTAssertThrowsError(try p.validate())
    }
    func testAudioLayerBoundsAndUniqueIDs() {
        var p = Fixtures.project(); let audio = AudioClip(url: Fixtures.url("music.m4a"), start: 0, duration: 5)
        p.music = [audio,audio]; XCTAssertThrowsError(try p.validate())
        p.music = [audio]; p.music?[0].volume = 3; XCTAssertThrowsError(try p.validate())
        p.music?[0].volume = 1; p.music?[0].fadeIn = -1; XCTAssertThrowsError(try p.validate())
    }
    func testTranscriptSourceBoundsAndDuplicateSegments() {
        var p = Fixtures.project(); let segment = TranscriptSegment(start: 0, end: 6, text: "Too long")
        p.transcripts = [SourceTranscript(mediaID: p.media[0].id, audioTrack: 0, language: "en", segments: [segment])]; XCTAssertThrowsError(try p.validate())
        p.transcripts?[0].segments[0].end = 1
        let duplicate = p.transcripts![0].segments[0]; p.transcripts?[0].segments.append(duplicate); XCTAssertThrowsError(try p.validate())
    }
    func testKeyframeDuplicateTimesAndIDsRejected() {
        var p = Fixtures.project(); var a = ClipAdjustments()
        let frame = TransformKeyframe(sourceTime: 1, zoom: 1, x: 0, y: 0, rotation: 0)
        a.keyframes = [frame,frame]; p.clips[0].adjustments = a; XCTAssertThrowsError(try p.validate())
        a.keyframes?[1].id = UUID(); p.clips[0].adjustments = a; XCTAssertThrowsError(try p.validate())
    }
    func testEmptyCaptionTextRejected() {
        for text in ["", " \n\t"] { XCTAssertThrowsError(try TranscriptSegment(start: 0, end: 1, text: text).validate()) }
    }
    func testInvalidSavePreservesExistingProject() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.cutline"); var p = Fixtures.project(); try p.write(to: url); let original = try Data(contentsOf: url)
        p.version = 99; XCTAssertThrowsError(try p.write(to: url)); XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testCorruptOrFutureProjectFailsToLoad() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("corrupt.cutline")
        for data in [Data("{".utf8),Data("{\"version\":999}".utf8)] { try data.write(to: url); XCTAssertThrowsError(try EditProject.read(from: url)) }
    }
    func testMarkerDuplicateIDsRejected() {
        var p = Fixtures.project(); let marker = HighlightMarker(clipID: p.clips[0].id, sourceTime: 1, label: "Moment"); p.markers = [marker,marker]; XCTAssertThrowsError(try p.validate())
    }
}
