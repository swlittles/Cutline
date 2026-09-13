import Foundation
import AVFoundation
import CoreGraphics

public struct ClipScanProgress: Sendable {
    public var fraction: Double
    public var message: String
    public init(_ fraction: Double, _ message: String) { self.fraction = fraction; self.message = message }
}

public enum ClipMediaScanner {
    /// Runs away from the main actor. Only measurements are retained, never a movie's worth of frames.
    public static func scan(media: MediaItem, settings: AutoClipSettings, markers: [ClipEvidence] = [], progress: @escaping @Sendable (ClipScanProgress) -> Void = { _ in }) async throws -> AutoClipReport {
        try settings.validate(); try Task.checkCancellation()
        guard media.url.isFileURL, media.duration.isFinite, (0.1...86400).contains(media.duration) else { throw EditError.invalid("Choose a local recording between 0.1 seconds and 24 hours.") }
        let asset = AVURLAsset(url: media.url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, abs(duration - media.duration) < 0.5 else { throw EditError.invalid("The source duration changed. Relink or reimport the recording before scanning.") }
        var audio: [ClipAudioSample] = [], motion: [ClipMotionSample] = [], evidence = markers.filter { $0.signal == .marker }
        var warnings = ["Activity scores are measurements, not judgments of clip quality. Review each clip."]
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if settings.audioEnabled {
            guard tracks.indices.contains(settings.audioTrack) else { throw EditError.invalid("The selected audio track is unavailable. Choose an existing track or disable audio detection.") }
            audio = try await readAudio(asset: asset, track: tracks[settings.audioTrack], duration: duration) { progress(ClipScanProgress($0 * 0.35, "Measuring audio track \(settings.audioTrack + 1)…")) }
            evidence += AutoClipRules.audioEvents(audio, settings: settings)
            warnings.append("Track \(settings.audioTrack + 1) is measured independently. Loud game audio, music, and voice chat can all trigger it; select an isolated mic track for reactions.")
        }
        var frames = 0, ocrReads = 0
        if settings.visionEnabled || settings.useOCR {
            guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw EditError.invalid("No video track is available for visual sampling.") }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: settings.useOCR ? 1920 : 320, height: settings.useOCR ? 1080 : 180)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            defer { generator.cancelAllCGImageGeneration() }
            var previous: [UInt8]?, tracker = ClipFeedTracker(), lastTime = -1.0
            var previousHUD: [UInt8]?, lastOCR = -Double.infinity, reads: [HUDRead] = []
            let count = Int(ceil(duration * settings.sampleFPS))
            for i in 0..<count {
                try Task.checkCancellation()
                let requested = Double(i) / settings.sampleFPS
                let result = try await withTaskCancellationHandler { try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 600)) } onCancel: { generator.cancelAllCGImageGeneration() }
                let time = result.actualTime.seconds
                guard time.isFinite, abs(time - requested) <= 0.5 else { throw EditError.invalid("Video sampling returned an inaccurate timestamp.") }
                if time <= lastTime { continue }
                lastTime = time; frames += 1
                try autoreleasepool {
                    if settings.visionEnabled {
                        let gray = try grayscale(result.image, region: settings.motionRegion)
                        if let previous { motion.append(difference(previous, gray, time: time)) }
                        previous = gray
                    }
                    if settings.useOCR {
                        guard let crop = crop(result.image, region: settings.hud) else { throw EditError.invalid("Cannot crop the HUD region.") }
                        let pixels = try grayscale(crop, region: ClipScanRegion())
                        let changed = previousHUD.map { difference($0, pixels, time: time).change > 0.008 } ?? true
                        if changed || time - lastOCR >= 1 {
                            reads = try ClipHUD.read(crop, aliases: settings.playerNames)
                            previousHUD = pixels; lastOCR = time; ocrReads += 1
                        }
                        evidence += tracker.update(at: time, reads: reads)
                    }
                }
                if i % max(1, Int(settings.sampleFPS)) == 0 { progress(ClipScanProgress(0.35 + 0.6 * Double(i + 1) / Double(count), "Sampling video \(timecode(time)) / \(timecode(duration))…")) }
            }
            evidence += AutoClipRules.motionEvents(motion, settings: settings)
        }
        try Task.checkCancellation()
        if settings.useOCR { warnings.append("HUD OCR assumes the configured player and region are visible. Spectator views, assist icons, name collisions, HUD changes, or missed text can produce errors. No game-specific accuracy has been established on real footage.") }
        let candidates = AutoClipRules.candidates(evidence: evidence, duration: duration, settings: settings)
        progress(ClipScanProgress(1, "Found \(candidates.count) \(candidates.count == 1 ? "clip" : "clips") to review."))
        return AutoClipReport(media: media, settings: settings, candidates: candidates, evidence: evidence.sorted { $0.time < $1.time }, audioSamples: audio, motionSamples: motion, warnings: warnings, sampledFrames: frames, ocrReads: ocrReads)
    }

    static func readAudio(asset: AVAsset, track: AVAssetTrack, duration: Double, progress: (Double) -> Void) async throws -> [ClipAudioSample] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditError.invalid("This audio track cannot be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError.invalid("Cannot start audio analysis.") }
        defer { reader.cancelReading() }
        var bins: [Int: (sum: Double, count: Int)] = [:], lastProgress = -1
        var activeBin = -1, sum = 0.0, count = 0
        func flush() {
            guard count > 0 else { return }
            let old = bins[activeBin] ?? (0, 0)
            bins[activeBin] = (old.sum + sum, old.count + count)
            sum = 0; count = 0
        }
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let format = CMSampleBufferGetFormatDescription(buffer), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { throw EditError.invalid("Unsupported decoded PCM layout.") }
                let size = CMBlockBufferGetDataLength(block)
                var floats = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
                let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { throw EditError.invalid("Cannot read decoded audio samples.") }
                let channels = Int(asbd.mChannelsPerFrame), start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                guard start.isFinite else { throw EditError.invalid("Audio samples have no valid timestamps.") }
                for frame in 0..<(floats.count / channels) {
                    let time = start + Double(frame) / asbd.mSampleRate
                    guard time >= 0, time < duration else { continue }
                    var energy = 0.0
                    for channel in 0..<channels { let value = Double(floats[frame * channels + channel]); guard value.isFinite else { throw EditError.invalid("Audio contains nonfinite samples.") }; energy += value * value }
                    let bin = Int(floor(time * 4))
                    if bin != activeBin { flush(); activeBin = bin }; sum += energy / Double(channels); count += 1
                }
                let percent = Int(start / duration * 100)
                if percent != lastProgress { lastProgress = percent; progress(min(1, max(0, start / duration))) }
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? EditError.invalid("Audio decoding did not complete.") }
        flush()
        return bins.keys.sorted().map { key in
            let value = bins[key]!
            return ClipAudioSample(time: Double(key) / 4, db: max(-100, 10 * log10(max(1e-10, value.sum / Double(max(1, value.count))))))
        }
    }
    static func crop(_ image: CGImage, region: ClipScanRegion) -> CGImage? {
        guard region.valid else { return nil }
        return image.cropping(to: CGRect(x: region.x * Double(image.width), y: region.y * Double(image.height), width: region.width * Double(image.width), height: region.height * Double(image.height)).integral)
    }
    static func grayscale(_ image: CGImage, region: ClipScanRegion) throws -> [UInt8] {
        guard let crop = crop(image, region: region) else { throw EditError.invalid("Invalid frame region.") }
        var data = [UInt8](repeating: 0, count: 64 * 36)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low; context.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 36)); return true
        }
        guard ok else { throw EditError.invalid("Cannot measure frame luminance.") }
        return data
    }
    public static func difference(_ a: [UInt8], _ b: [UInt8], time: Double) -> ClipMotionSample {
        guard a.count == b.count, !a.isEmpty else { return ClipMotionSample(time: time, change: 0) }
        var total = 0, changed = 0
        for i in a.indices { let delta = abs(Int(a[i]) - Int(b[i])); total += delta; if delta > 90 { changed += 1 } }
        let mean = Double(total) / Double(a.count) / 255
        return ClipMotionSample(time: time, change: mean, sceneCut: mean > 0.45 && Double(changed) / Double(a.count) > 0.8)
    }
}
