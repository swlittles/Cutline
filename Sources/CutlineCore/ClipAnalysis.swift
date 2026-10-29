import Foundation
import AVFoundation
import CoreGraphics
import CryptoKit

/// Inputs that require sampling the video again. Thresholds, timing and track choices do not.
public struct ClipVisualKey: Codable, Hashable, Sendable {
    public var motion: Bool
    public var motionRegion: ClipScanRegion
    public var sampleFPS: Double
    public var ocr: Bool
    public var hud: ClipScanRegion
    public var playerNames: [String]
    public init(_ settings: AutoClipSettings) {
        motion = settings.visionEnabled; motionRegion = settings.motionRegion; sampleFPS = settings.sampleFPS
        ocr = settings.useOCR; hud = settings.useOCR ? settings.hud : ClipScanRegion(); playerNames = settings.useOCR ? settings.playerNames : []
    }
    public var needed: Bool { motion || ocr }
    /// A broader sampling pass (for example motion plus OCR) still serves a narrower request.
    public func serves(_ other: ClipVisualKey) -> Bool {
        guard other.needed else { return true }
        guard motionRegion == other.motionRegion, sampleFPS == other.sampleFPS else { return false }
        if other.motion && !motion { return false }
        if other.ocr && !(ocr && hud == other.hud && playerNames == other.playerNames) { return false }
        return true
    }
}

/// Measurements of one recording. Audio covers every embedded track, so choosing a
/// different detection track or changing sensitivity never requires decoding again.
public struct ClipAnalysis: Codable, Equatable, Sendable {
    public var media: MediaItem
    public var audioTracks: [Int: [ClipAudioSample]]?
    public var visual: ClipVisualKey?
    public var motionSamples: [ClipMotionSample] = []
    public var hudEvidence: [ClipEvidence] = []
    public var sampledFrames = 0
    public var ocrReads = 0
    public init(media: MediaItem) { self.media = media }

    public var audioReady: Bool { audioTracks != nil }
    public func covers(_ settings: AutoClipSettings) -> Bool {
        if settings.audioEnabled && audioTracks?[settings.audioTrack] == nil { return false }
        let key = ClipVisualKey(settings)
        return !key.needed || (visual?.serves(key) ?? false)
    }
    /// Evaluation is cheap: rules run over retained measurements only.
    public func report(settings: AutoClipSettings, markers: [ClipEvidence] = []) throws -> AutoClipReport {
        try settings.validate()
        guard covers(settings) else { throw EditError.invalid("These settings need a new scan of the recording.") }
        var evidence = markers.filter { $0.signal == .marker && $0.time.isFinite && $0.time >= 0 && $0.time < media.duration }
        var warnings = ["Activity scores are measurements, not judgments of clip quality. Review each clip."]
        var audio: [ClipAudioSample] = []
        if settings.audioEnabled {
            audio = audioTracks?[settings.audioTrack] ?? []
            evidence += AutoClipRules.audioEvents(audio, settings: settings)
            warnings.append("Track \(settings.audioTrack + 1) is measured independently. Loud game audio, music, and voice chat can all trigger it; select an isolated mic track for reactions.")
        }
        if settings.visionEnabled { evidence += AutoClipRules.motionEvents(motionSamples, settings: settings) }
        if settings.useOCR {
            evidence += hudEvidence
            warnings.append("HUD OCR assumes the configured player and region are visible. Spectator views, assist icons, name collisions, HUD changes, or missed text can produce errors. No game-specific accuracy has been established on real footage.")
        }
        let candidates = AutoClipRules.candidates(evidence: evidence, duration: media.duration, settings: settings)
        return AutoClipReport(media: media, settings: settings, candidates: candidates, evidence: evidence.sorted { $0.time < $1.time }, audioSamples: audio, motionSamples: settings.visionEnabled ? motionSamples : [], warnings: warnings, sampledFrames: settings.visionEnabled || settings.useOCR ? sampledFrames : 0, ocrReads: settings.useOCR ? ocrReads : 0)
    }
}

public enum ClipAnalyzer {
    /// Measures whatever `existing` lacks for `settings`. Audio and video are sampled concurrently.
    public static func analyze(media: MediaItem, settings: AutoClipSettings, existing: ClipAnalysis? = nil,
                               progress: @escaping @Sendable (ClipScanProgress) -> Void = { _ in },
                               audioReady: @escaping @Sendable ([Int: [ClipAudioSample]]) -> Void = { _ in }) async throws -> ClipAnalysis {
        try settings.validate(); try Task.checkCancellation()
        guard media.url.isFileURL, media.duration.isFinite, (0.1...86400).contains(media.duration) else { throw EditError.invalid("Choose a local recording between 0.1 seconds and 24 hours.") }
        let asset = AVURLAsset(url: media.url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, abs(duration - media.duration) < 0.5 else { throw EditError.invalid("The source duration changed. Relink or reimport the recording before scanning.") }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count <= 64 else { throw EditError.invalid("Recordings with more than 64 audio tracks are not supported.") }
        if settings.audioEnabled && !tracks.indices.contains(settings.audioTrack) { throw EditError.invalid("The selected audio track is unavailable. Choose an existing track or disable audio detection.") }
        var result = existing.flatMap { $0.media.sameSource(as: media) ? $0 : nil } ?? ClipAnalysis(media: media)
        let needAudio = !result.audioReady && !tracks.isEmpty
        let key = ClipVisualKey(settings)
        let needVisual = key.needed && !(result.visual?.serves(key) ?? false)
        if !needAudio && !needVisual { return result }
        let share = Weights(audio: needAudio, visual: needVisual)
        async let audioPass: [Int: [ClipAudioSample]]? = needAudio ? readAllAudio(asset: asset, tracks: tracks, duration: duration) { fraction in
            progress(ClipScanProgress(fraction * share.audio, "Listening for big reactions…"))
        } : nil
        async let visualPass: VisualResult? = needVisual ? sampleVideo(asset: asset, key: key, duration: duration) { fraction, time in
            progress(ClipScanProgress(share.audio + fraction * share.visual, "Watching the gameplay · \(timecode(time)) of \(timecode(duration))"))
        } : nil
        if let audio = try await audioPass { result.audioTracks = audio; audioReady(audio) }
        else if result.audioTracks == nil && tracks.isEmpty { result.audioTracks = [:] }
        if let visual = try await visualPass {
            result.visual = key; result.motionSamples = visual.motion; result.hudEvidence = visual.hud
            result.sampledFrames = visual.frames; result.ocrReads = visual.reads
        }
        try Task.checkCancellation()
        progress(ClipScanProgress(1, "Almost done…"))
        return result
    }

    private struct Weights {
        let audio: Double, visual: Double
        init(audio a: Bool, visual v: Bool) { audio = a ? (v ? 0.35 : 1) : 0; visual = v ? 1 - audio : 0 }
    }
    struct VisualResult: Sendable { var motion: [ClipMotionSample]; var hud: [ClipEvidence]; var frames: Int; var reads: Int }

    /// One reader, one pass over the file, interleaved across outputs so no track's buffers pile up.
    static func readAllAudio(asset: AVAsset, tracks: [AVAssetTrack], duration: Double, progress: (Double) -> Void) async throws -> [Int: [ClipAudioSample]] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false]
        var outputs: [AVAssetReaderTrackOutput] = []
        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw EditError.invalid("An audio track cannot be decoded.") }
            reader.add(output); outputs.append(output)
        }
        guard reader.startReading() else { throw reader.error ?? EditError.invalid("Cannot start audio analysis.") }
        defer { reader.cancelReading() }
        var bins = Array(repeating: AudioBins(), count: outputs.count)
        var open = Set(outputs.indices), lastPercent = -1
        while !open.isEmpty {
            try Task.checkCancellation()
            for index in open.sorted() {
                guard let buffer = outputs[index].copyNextSampleBuffer() else { open.remove(index); continue }
                let start = try autoreleasepool { try bins[index].consume(buffer, duration: duration) }
                if index == open.min() {
                    let percent = Int(start / duration * 100)
                    if percent != lastPercent { lastPercent = percent; progress(min(1, max(0, start / duration))) }
                }
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? EditError.invalid("Audio decoding did not complete.") }
        var result: [Int: [ClipAudioSample]] = [:]
        for index in bins.indices { result[index] = bins[index].samples() }
        return result
    }

    /// Quarter-second mean energy across channels, as `ClipMediaScanner.readAudio` measures one track.
    struct AudioBins {
        private var bins: [Int: (sum: Double, count: Int)] = [:]
        private var active = -1, sum = 0.0, count = 0
        mutating func flush() {
            guard count > 0 else { return }
            let old = bins[active] ?? (0, 0); bins[active] = (old.sum + sum, old.count + count); sum = 0; count = 0
        }
        mutating func consume(_ buffer: CMSampleBuffer, duration: Double) throws -> Double {
            guard let format = CMSampleBufferGetFormatDescription(buffer), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { throw EditError.invalid("Unsupported decoded PCM layout.") }
            let size = CMBlockBufferGetDataLength(block), start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard start.isFinite else { throw EditError.invalid("Audio samples have no valid timestamps.") }
            guard size > 0 else { return start }
            guard size % MemoryLayout<Float>.size == 0 else { throw EditError.invalid("Invalid PCM sample buffer size.") }
            var floats = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw EditError.invalid("Cannot read decoded audio samples.") }
            let channels = Int(asbd.mChannelsPerFrame)
            for frame in 0..<(floats.count / channels) {
                let time = start + Double(frame) / asbd.mSampleRate
                guard time >= 0, time < duration else { continue }
                var energy = 0.0
                for channel in 0..<channels { let value = Double(floats[frame * channels + channel]); guard value.isFinite else { throw EditError.invalid("Audio contains nonfinite samples.") }; energy += value * value }
                let bin = Int(floor(time * 4))
                if bin != active { flush(); active = bin }; sum += energy / Double(channels); count += 1
            }
            return start
        }
        mutating func samples() -> [ClipAudioSample] {
            flush()
            return bins.keys.sorted().map { key in
                let value = bins[key]!
                return ClipAudioSample(time: Double(key) / 4, db: max(-100, 10 * log10(max(1e-10, value.sum / Double(max(1, value.count))))))
            }
        }
    }

    /// Where frames stop. Recordings often keep audio a few frames past the last video frame,
    /// and asking for a frame in that tail fails with "Cannot Open".
    static func videoEnd(_ asset: AVAsset, duration: Double) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditError.invalid("No video track is available for visual sampling.") }
        let end = try await track.load(.timeRange).end.seconds
        return end.isFinite && end > 0 ? min(duration, end) : duration
    }

    static func sampleVideo(asset: AVAsset, key: ClipVisualKey, duration: Double, progress: @escaping (Double, Double) -> Void) async throws -> VisualResult {
        let videoEnd = try await ClipAnalyzer.videoEnd(asset, duration: duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: key.ocr ? 1920 : 320, height: key.ocr ? 1080 : 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        defer { generator.cancelAllCGImageGeneration() }
        var result = VisualResult(motion: [], hud: [], frames: 0, reads: 0)
        var previous: [UInt8]?, tracker = ClipFeedTracker(), lastTime = -1.0
        var previousHUD: [UInt8]?, lastOCR = -Double.infinity, reads: [HUDRead] = []
        let count = Int(ceil(videoEnd * key.sampleFPS))
        for i in 0..<count {
            try Task.checkCancellation()
            let requested = Double(i) / key.sampleFPS
            let image = try await withTaskCancellationHandler { try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 600)) } onCancel: { generator.cancelAllCGImageGeneration() }
            let time = image.actualTime.seconds
            guard time.isFinite, abs(time - requested) <= 0.5 else { throw EditError.invalid("Video sampling returned an inaccurate timestamp.") }
            if time <= lastTime { continue }
            lastTime = time; result.frames += 1
            try autoreleasepool {
                if key.motion {
                    let gray = try ClipMediaScanner.grayscale(image.image, region: key.motionRegion)
                    if let previous { result.motion.append(ClipMediaScanner.difference(previous, gray, time: time)) }
                    previous = gray
                }
                if key.ocr {
                    guard let crop = ClipMediaScanner.crop(image.image, region: key.hud) else { throw EditError.invalid("Cannot crop the HUD region.") }
                    let pixels = try ClipMediaScanner.grayscale(crop, region: ClipScanRegion())
                    let changed = previousHUD.map { ClipMediaScanner.difference($0, pixels, time: time).change > 0.008 } ?? true
                    if changed || time - lastOCR >= 1 {
                        reads = try ClipHUD.read(crop, aliases: key.playerNames)
                        previousHUD = pixels; lastOCR = time; result.reads += 1
                    }
                    result.hud += tracker.update(at: time, reads: reads)
                }
            }
            if i % max(1, Int(key.sampleFPS)) == 0 { progress(Double(i + 1) / Double(count), time) }
        }
        return result
    }
}

/// Measurements persist between launches so reopening a recording is instant.
/// Keys cover the path, size, modification date and duration; any change forces a new scan.
public enum ClipAnalysisCache {
    static let limit = 24
    public static func key(for media: MediaItem) -> String? {
        guard let values = try? media.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize else { return nil }
        let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(media.url.standardizedFileURL.path)|\(size)|\(stamp)|\(media.duration)|\(media.audioTrackCount ?? -1)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func directory(_ root: URL) -> URL { root.appendingPathComponent("Analysis", isDirectory: true) }
    public static func load(for media: MediaItem, root: URL = LocalTools.support) -> ClipAnalysis? {
        guard let key = key(for: media), let data = try? Data(contentsOf: directory(root).appendingPathComponent(key + ".json")),
              var analysis = try? JSONDecoder().decode(ClipAnalysis.self, from: data), analysis.media.url == media.url, analysis.media.duration == media.duration else { return nil }
        // The cached item may carry an old identifier; measurements belong to the file, not the project.
        analysis.media = media
        return analysis
    }
    public static func save(_ analysis: ClipAnalysis, root: URL = LocalTools.support) throws {
        guard let key = key(for: analysis.media) else { return }
        let folder = directory(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stored = analysis; stored.media.shortFraming = nil; stored.media.audioRoles = nil
        let target = folder.appendingPathComponent(key + ".json")
        try JSONEncoder().encode(stored).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        if files.count > limit {
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) { try? FileManager.default.removeItem(at: url) }
        }
    }
}

public enum AudioTrackNames {
    /// Track titles written by the recorder, when present (for example "Mic" or "Desktop").
    public static func load(_ url: URL) async -> [String?] {
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio) else { return [] }
        var names: [String?] = []
        for track in tracks {
            let items = (try? await track.load(.metadata)) ?? []
            var name: String?
            for item in items where item.commonKey == .commonKeyTitle || item.identifier == .quickTimeUserDataTrackName || item.identifier == .quickTimeMetadataTitle {
                if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespaces).isEmpty { name = String(value.prefix(40)); break }
            }
            names.append(name)
        }
        return names
    }
}
