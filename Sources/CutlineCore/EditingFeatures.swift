import Foundation

public struct ProjectSettings: Codable, Equatable, Sendable {
    public var fps = 30
    public var resolution = 1080
    public var burnCaptions = true
    public init() {}
    public func size(for format: CanvasFormat) -> CGSize {
        let scale = Double(resolution) / 1080
        return CGSize(width: format.size.width * scale, height: format.size.height * scale)
    }
}

public struct TransformKeyframe: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var sourceTime: Double
    public var zoom: Double
    public var x: Double
    public var y: Double
    public var rotation: Double
    public init(sourceTime: Double, zoom: Double, x: Double, y: Double, rotation: Double) {
        self.sourceTime = sourceTime; self.zoom = zoom; self.x = x; self.y = y; self.rotation = rotation
    }
}

public struct ClipAdjustments: Codable, Equatable, Sendable {
    public var speed = 1.0
    public var fill = false
    public var zoom = 1.0
    public var x = 0.0
    public var y = 0.0
    public var rotation = 0.0
    public var mirror = false
    public var brightness = 0.0
    public var contrast = 1.0
    public var saturation = 1.0
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    public var audioGains: [String: Double] = [:]
    public var keyframes: [TransformKeyframe]?
    public var smoothKeyframes: Bool?
    public init() {}
    public func interpolated(at time: Double) -> ClipAdjustments {
        guard let frames = keyframes?.sorted(by: { $0.sourceTime < $1.sourceTime }), let first = frames.first else { return self }
        let before = frames.last(where: { $0.sourceTime <= time }) ?? first
        let after = frames.first(where: { $0.sourceTime >= time }) ?? frames.last!
        let span = after.sourceTime - before.sourceTime
        var fraction = span > 0 ? max(0, min(1, (time - before.sourceTime) / span)) : 0
        if smoothKeyframes == true { fraction = fraction * fraction * (3 - 2 * fraction) }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        var result = self
        result.zoom = mix(before.zoom, after.zoom); result.x = mix(before.x, after.x); result.y = mix(before.y, after.y); result.rotation = mix(before.rotation, after.rotation)
        return result
    }
}

public struct OverlayClip: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var mediaID: UUID
    public var start: Double
    public var sourceIn: Double
    public var duration: Double
    public var x = 0.72
    public var y = 0.08
    public var width = 0.25
    public var opacity = 1.0
    public init(mediaID: UUID, start: Double, sourceIn: Double = 0, duration: Double) {
        self.mediaID = mediaID; self.start = start; self.sourceIn = sourceIn; self.duration = duration
    }
}

public struct AudioClip: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var url: URL
    public var start: Double
    public var sourceIn: Double = 0
    public var duration: Double
    public var volume = 1.0
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    public init(url: URL, start: Double, duration: Double) { self.url = url; self.start = start; self.duration = duration }
}

public struct HighlightMarker: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var clipID: UUID
    public var sourceTime: Double
    public var label: String
    public init(clipID: UUID, sourceTime: Double, label: String) { self.clipID = clipID; self.sourceTime = sourceTime; self.label = label }
}

public extension EditProject {
    mutating func copyCaptions(from oldID: UUID, to newID: UUID) {
        guard let target = clips.first(where: { $0.id == newID }), let original = clips.first(where: { $0.id == oldID }) else { return }
        let copies = (captionTrack?.cues ?? []).filter { $0.clipID == oldID && $0.sourceStart < target.sourceOut && $0.sourceEnd > target.sourceIn }.map { cue -> CaptionCue in
            var copy = cue; copy.id = UUID(); copy.clipID = newID; return copy
        }
        captionTrack?.cues.append(contentsOf: copies)
        captionTrack?.cues.removeAll { $0.clipID == oldID && ($0.sourceStart >= original.sourceOut || $0.sourceEnd <= original.sourceIn) }
    }
    mutating func removeClip(_ id: UUID) {
        clips.removeAll { $0.id == id }
        captionTrack?.cues.removeAll { $0.clipID == id }
        markers?.removeAll { $0.clipID == id }
    }
    mutating func keepTimelineRange(start: Double, end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.01 else { throw EditError.invalid("Invalid highlight range.") }
        let original = self
        var result: [TimelineClip] = []
        var clipStart = 0.0
        for clip in original.clips {
            defer { clipStart += clip.duration }
            let low = max(start, clipStart), high = min(end, clipStart + clip.duration)
            if high - low >= 0.01 {
                var trimmed = clip
                trimmed.sourceIn = clip.sourceIn + (low - clipStart) * clip.speed
                trimmed.sourceOut = clip.sourceIn + (high - clipStart) * clip.speed
                result.append(trimmed)
            }
        }
        clips = result
        let ids = Set(result.map(\.id))
        captionTrack?.cues.removeAll { !ids.contains($0.clipID) }
        markers?.removeAll { !ids.contains($0.clipID) }
        overlays = (overlays ?? []).compactMap { overlay in
            let low = max(start, overlay.start), high = min(end, overlay.start + overlay.duration)
            guard high > low else { return nil }
            var copy = overlay; copy.sourceIn += low - overlay.start; copy.start = low - start; copy.duration = high - low; return copy
        }
        music = (music ?? []).compactMap { audio in
            let low = max(start, audio.start), high = min(end, audio.start + audio.duration)
            guard high > low else { return nil }
            var copy = audio; copy.sourceIn += low - audio.start; copy.start = low - start; copy.duration = high - low; return copy
        }
        try validate()
    }
    /// Ripple edit every track through the same retained ranges. New IDs keep repeated source ranges independent.
    mutating func keepTimelineRanges(_ ranges: [TimelineRange]) throws {
        let ordered = ranges.sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { throw EditError.invalid("Keep at least one part of the timeline.") }
        var previousEnd = 0.0
        for range in ordered {
            guard range.start.isFinite, range.end.isFinite, range.start >= previousEnd, range.end > range.start,
                  range.end <= duration + 0.001 else { throw EditError.invalid("The retained ranges overlap or exceed the timeline.") }
            previousEnd = range.end
        }
        let original = self
        var result = original
        result.clips = []; result.captionTrack?.cues = []; result.markers = []; result.overlays = []; result.music = []
        var offset = 0.0
        for range in ordered {
            var part = original
            try part.keepTimelineRange(start: range.start, end: range.end)
            var mapping: [UUID: UUID] = [:]
            for index in part.clips.indices { let old = part.clips[index].id; part.clips[index].id = UUID(); mapping[old] = part.clips[index].id }
            let cues = (part.captionTrack?.cues ?? []).compactMap { cue -> CaptionCue? in
                guard let id = mapping[cue.clipID], let clip = part.clips.first(where: { $0.id == id }), cue.sourceStart < clip.sourceOut, cue.sourceEnd > clip.sourceIn else { return nil }
                var copy = cue; copy.id = UUID(); copy.clipID = id
                copy.sourceStart = max(copy.sourceStart, clip.sourceIn); copy.sourceEnd = min(copy.sourceEnd, clip.sourceOut)
                return copy
            }
            let markers = (part.markers ?? []).compactMap { marker -> HighlightMarker? in
                guard let id = mapping[marker.clipID], let clip = part.clips.first(where: { $0.id == id }), marker.sourceTime >= clip.sourceIn, marker.sourceTime < clip.sourceOut else { return nil }
                var copy = marker; copy.id = UUID(); copy.clipID = id; return copy
            }
            result.clips += part.clips; result.captionTrack?.cues += cues; result.markers? += markers
            result.overlays? += (part.overlays ?? []).map { var copy = $0; copy.id = UUID(); copy.start += offset; return copy }
            result.music? += (part.music ?? []).map { var copy = $0; copy.id = UUID(); copy.start += offset; return copy }
            offset += part.duration
        }
        try result.validate(); self = result
    }
    mutating func removeTimelineRanges(_ ranges: [TimelineRange]) throws {
        let cuts = TimelineRange.merged(ranges, duration: duration)
        var keeps: [TimelineRange] = [], cursor = 0.0
        for cut in cuts {
            if cut.start - cursor >= 0.01 { keeps.append(TimelineRange(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if duration - cursor >= 0.01 { keeps.append(TimelineRange(start: cursor, end: duration)) }
        guard !cuts.isEmpty else { return }
        try keepTimelineRanges(keeps)
    }
    func speechGaps(minimum: Double = 1.0, padding: Double = 0.2) -> [TimelineRange] {
        guard minimum.isFinite, padding.isFinite, minimum >= 0.1, padding >= 0 else { return [] }
        let cues = projectedCaptions()
        guard !cues.isEmpty else { return [] }
        let speech = TimelineRange.merged(cues.map { TimelineRange(start: max(0, $0.start - padding), end: min(duration, $0.end + padding)) }, duration: duration)
        var result: [TimelineRange] = [], cursor = 0.0
        for range in speech { if range.start - cursor >= minimum { result.append(TimelineRange(start: cursor, end: range.start)) }; cursor = range.end }
        if duration - cursor >= minimum { result.append(TimelineRange(start: cursor, end: duration)) }
        return result
    }
    func validateExtras() throws {
        guard Set((overlays ?? []).map(\.id)).count == (overlays ?? []).count,
              Set((music ?? []).map(\.id)).count == (music ?? []).count,
              Set((markers ?? []).map(\.id)).count == (markers ?? []).count,
              Set((transcripts ?? []).map(\.id)).count == (transcripts ?? []).count else { throw EditError.invalid("The project contains duplicate layer or transcript identifiers.") }

        guard [24, 25, 30, 50, 60].contains(options.fps), [720, 1080, 2160].contains(options.resolution) else { throw EditError.invalid("Invalid output settings.") }
        for clip in clips {
            let a = clip.adjustments ?? ClipAdjustments()
            guard [a.speed,a.zoom,a.x,a.y,a.rotation,a.brightness,a.contrast,a.saturation,a.fadeIn,a.fadeOut].allSatisfy(\.isFinite),
                  (0.1...8).contains(a.speed), (0.1...8).contains(a.zoom), (-2...2).contains(a.x), (-2...2).contains(a.y),
                  (-360...360).contains(a.rotation), (-1...1).contains(a.brightness), (0...4).contains(a.contrast), (0...3).contains(a.saturation),
                  a.fadeIn >= 0, a.fadeOut >= 0, a.audioGains.values.allSatisfy({ $0.isFinite && (0...2).contains($0) }) else { throw EditError.invalid("Invalid clip adjustments.") }
        }
        for clip in clips {
            let frames = clip.adjustments?.keyframes ?? []
            guard Set(frames.map(\.id)).count == frames.count, Set(frames.map(\.sourceTime)).count == frames.count else { throw EditError.invalid("Transform keyframes must have unique IDs and times.") }
            for keyframe in frames {
                guard [keyframe.sourceTime,keyframe.zoom,keyframe.x,keyframe.y,keyframe.rotation].allSatisfy(\.isFinite), keyframe.sourceTime >= 0, (0.1...8).contains(keyframe.zoom), (-2...2).contains(keyframe.x), (-2...2).contains(keyframe.y), (-360...360).contains(keyframe.rotation) else { throw EditError.invalid("Invalid transform keyframe.") }
            }
        }
        if let captions = captionTrack { try captions.validate(clipIDs: Set(clips.map(\.id))) }
        for transcript in transcripts ?? [] {
            guard media.contains(where: { $0.id == transcript.mediaID }), transcript.audioTrack >= 0 else { throw EditError.invalid("Invalid transcript source.") }
            guard Set(transcript.segments.map(\.id)).count == transcript.segments.count else { throw EditError.invalid("The transcript contains duplicate segment identifiers.") }
            let length = media.first { $0.id == transcript.mediaID }!.duration
            for segment in transcript.segments { try segment.validate(); guard segment.end <= length + 0.01 else { throw EditError.invalid("A transcript segment exceeds its source duration.") } }
        }
        for overlay in overlays ?? [] {
            guard let item = media.first(where: { $0.id == overlay.mediaID }),
                  [overlay.start,overlay.sourceIn,overlay.duration,overlay.x,overlay.y,overlay.width,overlay.opacity].allSatisfy(\.isFinite),
                  overlay.start >= 0, overlay.sourceIn >= 0, overlay.duration > 0, overlay.sourceIn + overlay.duration <= item.duration + 0.01,
                  (0...1).contains(overlay.x), (0...1).contains(overlay.y), (0.05...1).contains(overlay.width), (0...1).contains(overlay.opacity) else { throw EditError.invalid("Invalid overlay.") }
        }
        for audio in music ?? [] {
            guard audio.url.isFileURL, [audio.start,audio.sourceIn,audio.duration,audio.volume,audio.fadeIn,audio.fadeOut].allSatisfy(\.isFinite),
                  audio.start >= 0, audio.sourceIn >= 0, audio.duration > 0, (0...2).contains(audio.volume), audio.fadeIn >= 0, audio.fadeOut >= 0 else { throw EditError.invalid("Invalid audio layer.") }
        }
        for marker in markers ?? [] {
            guard clips.contains(where: { $0.id == marker.clipID }), marker.sourceTime.isFinite, marker.sourceTime >= 0 else { throw EditError.invalid("Invalid marker.") }
        }
    }
}

public struct TimelineRange: Identifiable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var id: String { "\(start)-\(end)" }
    public var duration: Double { end - start }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public static func merged(_ ranges: [TimelineRange], duration: Double) -> [TimelineRange] {
        let valid = ranges.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.end > 0 && $0.start < duration }.map { TimelineRange(start: max(0, $0.start), end: min(duration, $0.end)) }.sorted { $0.start < $1.start }
        var result: [TimelineRange] = []
        for range in valid {
            if let last = result.last, range.start <= last.end { result[result.count - 1].end = max(last.end, range.end) }
            else { result.append(range) }
        }
        return result
    }
}
