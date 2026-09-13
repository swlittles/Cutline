import XCTest
import AVFoundation
import CoreGraphics
@testable import CutlineCore

final class CompositionTests: XCTestCase {
    func testInspectRecognizesBothOBSAudioTracks() async throws {
        let media = try await CompositionEngine.inspect(Fixtures.url("gameplay.mp4"))
        XCTAssertEqual(media.audioTrackCount, 2); XCTAssertEqual(media.duration, 5, accuracy: 0.05)
    }
    func testAudioOnlyAndMissingInputAreRejected() async {
        for url in [Fixtures.url("music.m4a"),Fixtures.url("missing.mp4")] {
            do { _ = try await CompositionEngine.inspect(url); XCTFail("Expected rejection") } catch {}
        }
    }
    func testEmptyCompositionIsRejected() async {
        do { _ = try await CompositionEngine.build(EditProject()); XCTFail("Expected empty timeline error") } catch { XCTAssertTrue(error.localizedDescription.contains("Add a clip")) }
    }
    func testMissingMainVideoIsActionable() async {
        var project = Fixtures.project(); project.media[0].url = Fixtures.url("missing.mp4")
        do { _ = try await CompositionEngine.build(project); XCTFail("Expected missing media error") } catch { XCTAssertTrue(error.localizedDescription.contains("Relink")) }
    }
    func testSpeedChangesCompositionTimingAndIndependentAudioGains() async throws {
        var project = Fixtures.project(); var a = ClipAdjustments(); a.speed = 2; a.audioGains = ["0":0,"1":0.5]; project.clips[0].adjustments = a
        let render = try await CompositionEngine.build(project)
        XCTAssertEqual(render.asset.duration.seconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(render.audio.inputParameters.count, 2)
        var start: Float = 0, end: Float = 0; var range = CMTimeRange.zero
        XCTAssertTrue(render.audio.inputParameters[0].getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)); XCTAssertEqual(start, 0)
        XCTAssertTrue(render.audio.inputParameters[1].getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)); XCTAssertEqual(start, 0.5)
    }
    func testLayerClippingNeverExtendsProjectDuration() async throws {
        var project = Fixtures.project(); project.clips[0].sourceOut = 2
        project.overlays = [OverlayClip(mediaID: project.media[0].id, start: 1, duration: 4)]
        project.music = [AudioClip(url: Fixtures.url("music.m4a"), start: 1, duration: 4)]
        let render = try await CompositionEngine.build(project)
        XCTAssertEqual(render.asset.duration.seconds, 2, accuracy: 0.001)
    }
    func testCaptionBurnInChangesRenderedPixels() async throws {
        var project = Fixtures.project(); project.clips[0].sourceOut = 1
        let plain = try await pixels(project)
        project.generateCaptions(from: SourceTranscript(mediaID: project.media[0].id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 0, end: 1, text: "VICTORY FOR OUR TEAM")]))
        let captioned = try await pixels(project)
        XCTAssertGreaterThan(difference(plain, captioned), 500)
        project.options.burnCaptions = false
        let disabled = try await pixels(project)
        XCTAssertLessThan(difference(plain, disabled), 50)
    }
    func testBlackAndWhiteAdjustmentProducesGrayPixels() async throws {
        var project = Fixtures.project(); project.clips[0].sourceOut = 1
        project.clips[0].adjustments = ClipAdjustments(); project.clips[0].adjustments?.saturation = 0
        let values = try await pixels(project)
        var colored = 0
        for index in stride(from: 0, to: values.count, by: 4) { if abs(Int(values[index]) - Int(values[index+1])) > 12 || abs(Int(values[index+1]) - Int(values[index+2])) > 12 { colored += 1 } }
        XCTAssertLessThan(colored, values.count / 100)
    }
    func testOverlayOpacityChangesOnlyVisibleLayer() async throws {
        var project = Fixtures.project(); project.clips[0].sourceOut = 1
        let media = MediaItem(url: Fixtures.url("facecam.mp4"), duration: 3); project.media.append(media)
        let plain = try await pixels(project)
        var overlay = OverlayClip(mediaID: media.id, start: 0, duration: 1); overlay.x = 0.5; overlay.y = 0.1; overlay.width = 0.2
        project.overlays = [overlay]
        let visible = try await pixels(project); XCTAssertGreaterThan(difference(plain, visible), 1000)
        project.overlays?[0].opacity = 0
        let invisible = try await pixels(project); XCTAssertLessThan(difference(plain, invisible), 200)
    }
    func testPortraitAnd60FPSExportMetadata() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = Fixtures.project(); p.clips[0].sourceOut = 0.5; p.format = .portrait; p.options.fps = 60
        let url = root.appendingPathComponent("portrait.mp4"); let render = try await CompositionEngine.build(p)
        try await CompositionEngine.export(render, to: url)
        let asset = AVURLAsset(url: url), track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize), rate = try await track.load(.nominalFrameRate), duration = try await asset.load(.duration)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280)); XCTAssertEqual(rate, 60, accuracy: 0.1); XCTAssertEqual(duration.seconds, 0.5, accuracy: 0.05)
    }
    func testCancelledExportReportsCancellation() async throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let render = try await CompositionEngine.build(Fixtures.project())
        let task = Task { try Task.checkCancellation(); try await CompositionEngine.export(render, to: root.appendingPathComponent("cancel.mp4")) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testStillImageConversionPreservesDurationAndCanBeReused() async throws {
        guard LocalTools.executable("ffmpeg") != nil else { throw XCTSkip("FFmpeg required for still conversion") }
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await StillImageClip.make(from: Fixtures.url("artwork.png"), directory: root)
        let second = try await StillImageClip.make(from: Fixtures.url("artwork.png"), directory: root)
        XCTAssertEqual(first, second)
        let media = try await CompositionEngine.inspect(first); XCTAssertEqual(media.duration, 5, accuracy: 0.05); XCTAssertEqual(media.audioTrackCount, 0)
    }
    private func pixels(_ project: EditProject) async throws -> [UInt8] {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("render.mp4")
        let render = try await CompositionEngine.build(project); try await CompositionEngine.export(render, to: url)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600)).image
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        result.withUnsafeMutableBytes { bytes in
            let c = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        }
        return result
    }
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return Int.max }
        var count = 0
        for index in stride(from: 0, to: a.count, by: 4) { if abs(Int(a[index]) - Int(b[index])) + abs(Int(a[index+1]) - Int(b[index+1])) + abs(Int(a[index+2]) - Int(b[index+2])) > 100 { count += 1 } }
        return count
    }
}
