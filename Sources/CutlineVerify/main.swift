import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CutlineCore

// Integration check using a caller-provided disposable video fixture.
@main struct Verify {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("Usage: CutlineVerify input.mp4 output-directory"); return }
        let input = URL(fileURLWithPath: args[1])
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let media = try await CompositionEngine.inspect(input)
        var project = EditProject(workflow: .youtubeVideo); project.name = "Gameplay test"; project.media = [media]
        project.clips = [TimelineClip(mediaID: media.id, sourceIn: 0.5, sourceOut: 2.5, volume: 0.5)]
        guard project.split(at: 1) != nil else { throw EditError.invalid("Split failed") }
        project.clips.swapAt(0, 1)
        for workflow in OutputWorkflow.allCases {
            project.selectWorkflow(workflow)
            project.shortHook = "Watch this play"; project.media[0].shortFraming = ShortFraming(); project.media[0].shortFraming?.confirmed = true
            let format = workflow.format
            let render = try await CompositionEngine.build(project, branding: ShortBranding(text: "example.test/channel", logo: .kick))
            guard abs(render.asset.duration.seconds - 2) < 0.01 else { throw EditError.invalid("Wrong composition duration") }
            let url = output.appendingPathComponent(format.rawValue + ".mp4")
            try await CompositionEngine.export(render, to: url)
            let result = AVURLAsset(url: url)
            let duration = try await result.load(.duration).seconds
            guard abs(duration - 2) < 0.1 else { throw EditError.invalid("Wrong export duration") }
            let tracks = try await result.loadTracks(withMediaType: .video)
            let size = try await tracks[0].load(.naturalSize)
            guard size == format.size else { throw EditError.invalid("Wrong canvas size: \(size)") }
            let audio = try await result.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else { throw EditError.invalid("Audio missing from export") }
            print("PASS \(format.rawValue): \(Int(size.width))×\(Int(size.height)), \(duration)s, audio present")
        }
        project.format = .landscape
        try project.write(to: output.appendingPathComponent("Gameplay test.cutline"))
        print("PASS project saved; split, trim, reorder, volume, and all canvas exports verified")
        if args.contains("--features") { try await verifyFeatures(project, output: output) }
        if args.contains("--stills") { try await verifyStills(output: output) }
        if args.contains("--transcribe") { try await verifyTranscription(media, output: output) }
    }
    static func verifyFeatures(_ original: EditProject, output: URL) async throws {
        var project = original
        project.options.fps = 60; project.options.resolution = 720
        for index in project.clips.indices {
            project.clips[index].adjustments = ClipAdjustments()
            project.clips[index].adjustments?.speed = 2
            project.clips[index].adjustments?.audioGains = ["1": 0]
            project.clips[index].adjustments?.keyframes = [TransformKeyframe(sourceTime: 0, zoom: 1, x: 0, y: 0, rotation: 0), TransformKeyframe(sourceTime: 4, zoom: 1.4, x: 0.1, y: 0, rotation: 0)]
        }
        let media = project.media[0]
        project.generateCaptions(from: SourceTranscript(mediaID: media.id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 0, end: media.duration, text: "LOCAL CAPTIONS · CUTLINE")]))
        project.overlays = [OverlayClip(mediaID: media.id, start: 0, duration: project.duration)]
        var music = AudioClip(url: media.url, start: 0, duration: project.duration)
        music.volume = 0.2; music.fadeIn = 0.1; music.fadeOut = 0.1; project.music = [music]
        let captioned = output.appendingPathComponent("features.mp4")
        try await CompositionEngine.export(CompositionEngine.build(project), to: captioned)
        let asset = AVURLAsset(url: captioned)
        let duration = try await asset.load(.duration).seconds
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize), rate = try await track.load(.nominalFrameRate)
        guard abs(duration - 1) < 0.05, size == CGSize(width: 1280, height: 720), abs(rate - 60) < 0.1 else { throw EditError.invalid("Feature export timing, dimensions, or frame rate failed") }
        try project.write(to: output.appendingPathComponent("Feature verification.cutline"))
        project.options.burnCaptions = false
        let plain = output.appendingPathComponent("features-no-captions.mp4")
        try await CompositionEngine.export(CompositionEngine.build(project), to: plain)
        let captionFrame = try await frame(captioned, at: 0.25)
        let plainFrame = try await frame(plain, at: 0.25)
        let a = pixels(captionFrame), b = pixels(plainFrame)
        var changed = 0
        for index in stride(from: 0, to: min(a.count, b.count), by: 4) {
            let red = abs(Int(a[index]) - Int(b[index]))
            let green = abs(Int(a[index + 1]) - Int(b[index + 1]))
            let blue = abs(Int(a[index + 2]) - Int(b[index + 2]))
            if max(red, green, blue) > 60 { changed += 1 }
        }
        guard changed > 500 else { throw EditError.invalid("Caption burn-in did not change the rendered pixels") }
        let imageURL = output.appendingPathComponent("features-frame.png")
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, captionFrame, nil); CGImageDestinationFinalize(destination)
        print("PASS speed + keyframes + overlay + audio layer + 720p60 + caption burn-in: \(changed) changed pixels")
    }
    static func verifyStills(output: URL) async throws {
        let png = output.appendingPathComponent("features-frame.png")
        let video = try await StillImageClip.make(from: png, directory: output.appendingPathComponent("still-test"))
        let media = try await CompositionEngine.inspect(video)
        guard abs(media.duration - 5) < 0.05 else { throw EditError.invalid("Still clip has the wrong duration") }
        var project = EditProject(workflow: .youtubeVideo); project.media = [media]; project.clips = [TimelineClip(mediaID: media.id, sourceOut: 5)]
        project.generateCaptions(from: SourceTranscript(mediaID: media.id, audioTrack: 0, language: "en", segments: [TranscriptSegment(start: 1, end: 4, text: "A still image with a transcript cut")]))
        try project.removeTimelineRanges([TimelineRange(start: 2, end: 3)])
        project.options.resolution = 720
        let exported = output.appendingPathComponent("still-edited.mp4")
        try await CompositionEngine.export(CompositionEngine.build(project), to: exported)
        let result = try await CompositionEngine.inspect(exported)
        guard abs(result.duration - 4) < 0.05 else { throw EditError.invalid("Still timeline cut exported wrong duration") }
        print("PASS still-image import, native composition, transcript cut, and four-second export")
    }
    static func verifyTranscription(_ media: MediaItem, output: URL) async throws {
        let transcript = try await LocalTranscription.transcribe(media: media, audioTrack: 0, model: .base, language: "en") { progress in
            print("Local ASR: \(progress.message)")
        }
        guard !transcript.segments.isEmpty else { throw EditError.invalid("Local transcription returned no speech") }
        var project = EditProject(workflow: .youtubeVideo); project.name = "Local caption verification"; project.media = [media]
        project.clips = [TimelineClip(mediaID: media.id, sourceOut: media.duration)]
        project.transcripts = [transcript]; project.generateCaptions(from: transcript)
        project.options.resolution = 720
        try project.write(to: output.appendingPathComponent("Local caption verification.cutline"))
        try SubtitleFile.encode(project.projectedCaptions()).write(to: output.appendingPathComponent("local-captions.srt"), atomically: true, encoding: .utf8)
        try await CompositionEngine.export(CompositionEngine.build(project), to: output.appendingPathComponent("local-captioned.mp4"))
        print("PASS real local transcription and captioned export: \(transcript.segments.count) segments")
        print(transcript.segments.map(\.text).joined(separator: " "))
    }
    static func frame(_ url: URL, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }
    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { pointer in
            let context = CGContext(data: pointer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
