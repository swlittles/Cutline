@preconcurrency import AVFoundation
import Foundation

public struct RenderComposition {
    public let asset: AVMutableComposition
    public let video: AVMutableVideoComposition
    public let audio: AVMutableAudioMix
    let exportProject: EditProject
    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = video; item.audioMix = audio
        item.audioTimePitchAlgorithm = .timeDomain
        return item
    }
}

// AVFoundation exposes cancelExport specifically for cancelling an in-flight async export.
private final class ExportCancellation: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

public enum CompositionEngine {
    public static func inspect(_ url: URL) async throws -> MediaItem {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw EditError.invalid("\(url.lastPathComponent) has no video track. Use Add audio for music or voiceovers.") }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0.1 else { throw EditError.invalid("This video is too short or cannot be read.") }
        var item = MediaItem(url: url, duration: duration)
        item.audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        return item
    }
    public static func build(_ project: EditProject) async throws -> RenderComposition {
        try project.validate()
        guard !project.clips.isEmpty else { throw EditError.invalid("Add a clip to the timeline first.") }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EditError.invalid("Could not create a video track.") }
        var instructions: [FrameInstruction] = []
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        var overlayLayers: [LayerRecipe] = []
        let canvas = project.options.size(for: project.outputFormat)
        let captions = project.options.burnCaptions ? project.projectedCaptions() : []
        for overlay in project.overlays ?? [] where overlay.start < project.duration {
            guard let media = project.media.first(where: { $0.id == overlay.mediaID }) else { continue }
            let asset = AVURLAsset(url: media.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EditError.invalid("Overlay video is unavailable.") }
            let length = min(overlay.duration, project.duration - overlay.start)
            try track.insertTimeRange(CMTimeRange(start: time(overlay.sourceIn), duration: time(length)), of: source, at: time(overlay.start))
            overlayLayers.append(LayerRecipe(trackID: track.trackID, transform: try await source.load(.preferredTransform), overlay: overlay))
        }
        var cursor = CMTime.zero
        for clip in project.clips {
            try Task.checkCancellation()
            guard let media = project.media.first(where: { $0.id == clip.mediaID }), FileManager.default.fileExists(atPath: media.url.path) else { throw EditError.invalid("A source file is missing. Use Relink in the Media panel to locate it.") }
            let asset = AVURLAsset(url: media.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw EditError.invalid("\(media.name) has no readable video.") }
            let sourceRange = CMTimeRange(start: time(clip.sourceIn), duration: time(clip.sourceOut - clip.sourceIn))
            let targetDuration = time(clip.duration)
            try videoTrack.insertTimeRange(sourceRange, of: source, at: cursor)
            if clip.speed != 1 { videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration), toDuration: targetDuration) }
            let range = CMTimeRange(start: cursor, duration: targetDuration)
            let layer = LayerRecipe(trackID: videoTrack.trackID, transform: try await source.load(.preferredTransform))
            instructions.append(FrameInstruction(range: range, main: layer, overlays: overlayLayers.filter { ($0.overlay?.start ?? 0) < range.end.seconds && ($0.overlay!.start + $0.overlay!.duration) > range.start.seconds }, adjustments: clip.adjustments ?? ClipAdjustments(), captions: captions.filter { $0.start < range.end.seconds && $0.end > range.start.seconds }, style: project.captionTrack?.style ?? CaptionStyle(), sourceIn: clip.sourceIn, shortFraming: project.workflow == .mobileShort ? (media.shortFraming ?? ShortFraming()) : nil, hook: project.hook(for: clip)))
            let sources = try await asset.loadTracks(withMediaType: .audio)
            for (index, sourceAudio) in sources.enumerated() {
                guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let available = try await sourceAudio.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(sourceRange, otherRange: available)
                if intersection.duration.seconds > 0 {
                    let audioStart = cursor + time((intersection.start - sourceRange.start).seconds / clip.speed)
                    try audioTrack.insertTimeRange(intersection, of: sourceAudio, at: audioStart)
                    if clip.speed != 1 { audioTrack.scaleTimeRange(CMTimeRange(start: audioStart, duration: intersection.duration), toDuration: time(intersection.duration.seconds / clip.speed)) }
                    let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
                    parameters.audioTimePitchAlgorithm = .timeDomain
                    parameters.setVolume(Float(clip.volume * (clip.adjustments?.audioGains[String(index)] ?? 1)), at: cursor)
                    audioParameters.append(parameters)
                }
            }
            cursor = range.end
        }
        for audio in project.music ?? [] where audio.start < project.duration {
            let asset = AVURLAsset(url: audio.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EditError.invalid("An audio layer could not be loaded.") }
            let available = try await asset.load(.duration).seconds
            let length = min(audio.duration, project.duration - audio.start, available - audio.sourceIn)
            guard length > 0 else { continue }
            try track.insertTimeRange(CMTimeRange(start: time(audio.sourceIn), duration: time(length)), of: source, at: time(audio.start))
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(audio.volume), at: time(audio.start))
            let fadeIn = min(audio.fadeIn, length / 2), fadeOut = min(audio.fadeOut, length / 2)
            if fadeIn > 0 { parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(audio.volume), timeRange: CMTimeRange(start: time(audio.start), duration: time(fadeIn))) }
            if fadeOut > 0 { parameters.setVolumeRamp(fromStartVolume: Float(audio.volume), toEndVolume: 0, timeRange: CMTimeRange(start: time(audio.start + length - fadeOut), duration: time(fadeOut))) }
            audioParameters.append(parameters)
        }
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = CutlineVideoCompositor.self
        video.renderSize = canvas; video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(project.options.fps))
        video.instructions = instructions
        let audio = AVMutableAudioMix(); audio.inputParameters = audioParameters
        return RenderComposition(asset: composition, video: video, audio: audio, exportProject: project)
    }
    public static func export(_ render: RenderComposition, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        try render.exportProject.validateForExport()
        guard let session = AVAssetExportSession(asset: render.asset, presetName: AVAssetExportPresetHighestQuality) else { throw EditError.invalid("An export session could not be created.") }
        session.videoComposition = render.video; session.audioMix = render.audio
        session.outputURL = url; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        let observer = Task {
            while !Task.isCancelled { progress(Double(session.progress)); try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        defer { observer.cancel() }
        let cancellation = ExportCancellation(session)
        await withTaskCancellationHandler { await session.export() } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        guard session.status == .completed else { throw session.error ?? EditError.invalid("Export did not complete.") }
        progress(1)
    }
    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60000) }
}
