import Foundation

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
    public func validate() throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 10000 else { throw EditError.invalid("Invalid caption timing or text.") }
    }
}
public struct SourceTranscript: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var mediaID: UUID
    public var audioTrack: Int
    public var language: String
    public var segments: [TranscriptSegment]
    public init(mediaID: UUID, audioTrack: Int, language: String, segments: [TranscriptSegment]) {
        self.mediaID = mediaID; self.audioTrack = audioTrack; self.language = language; self.segments = segments
    }
}
public struct CaptionCue: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var clipID: UUID
    public var sourceStart: Double
    public var sourceEnd: Double
    public var text: String
    public init(clipID: UUID, sourceStart: Double, sourceEnd: Double, text: String) { self.clipID = clipID; self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.text = text }
}
public struct CaptionStyle: Codable, Equatable, Sendable {
    public var fontSize = 52.0
    public var bottom = 0.12
    public var uppercase = false
    public var colorHex = "FFFFFF"
    public var background = true
    public init() {}
}
public struct CaptionTrack: Codable, Equatable, Sendable {
    public var cues: [CaptionCue] = []
    public var style = CaptionStyle()
    public init() {}
    public func validate(clipIDs: Set<UUID>) throws {
        guard Set(cues.map(\.id)).count == cues.count, style.fontSize.isFinite, (16...140).contains(style.fontSize), style.bottom.isFinite, (0.02...0.9).contains(style.bottom),
              style.colorHex.count == 6, UInt32(style.colorHex, radix: 16) != nil else { throw EditError.invalid("Invalid caption style.") }
        for cue in cues {
            guard clipIDs.contains(cue.clipID) else { throw EditError.invalid("A caption references a missing clip.") }
            try TranscriptSegment(start: cue.sourceStart, end: cue.sourceEnd, text: cue.text).validate()
        }
    }
}
public struct ProjectedCaption: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
}
public extension EditProject {
    func projectedCaptions() -> [ProjectedCaption] {
        var starts: [UUID: Double] = [:]; var cursor = 0.0
        for clip in clips { starts[clip.id] = cursor; cursor += clip.duration }
        let lookup = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        return (captionTrack?.cues ?? []).compactMap { cue in
            guard let clip = lookup[cue.clipID], let timelineStart = starts[clip.id] else { return nil }
            let low = max(cue.sourceStart, clip.sourceIn), high = min(cue.sourceEnd, clip.sourceOut)
            guard high > low else { return nil }
            return ProjectedCaption(id: cue.id, start: timelineStart + (low - clip.sourceIn) / clip.speed, end: timelineStart + (high - clip.sourceIn) / clip.speed, text: cue.text)
        }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }
    mutating func generateCaptions(from transcript: SourceTranscript) {
        if captionTrack == nil { captionTrack = CaptionTrack() }
        for clip in clips where clip.mediaID == transcript.mediaID {
            captionTrack?.cues.removeAll { $0.clipID == clip.id }
            let cues = transcript.segments.filter { $0.start < clip.sourceOut && $0.end > clip.sourceIn }.map { CaptionCue(clipID: clip.id, sourceStart: $0.start, sourceEnd: $0.end, text: $0.text) }
            captionTrack?.cues.append(contentsOf: cues)
        }
    }
    mutating func importCaptions(_ segments: [TranscriptSegment]) {
        if captionTrack == nil { captionTrack = CaptionTrack() }
        for clip in clips {
            let position = start(of: clip.id)
            for segment in segments {
                let low = max(position, segment.start), high = min(position + clip.duration, segment.end)
                if high > low {
                    captionTrack?.cues.append(CaptionCue(clipID: clip.id, sourceStart: clip.sourceIn + (low - position) * clip.speed, sourceEnd: clip.sourceIn + (high - position) * clip.speed, text: segment.text))
                }
            }
        }
    }
}

public enum SubtitleFile {
    public static func encode(_ captions: [ProjectedCaption], vtt: Bool = false) -> String {
        let body = captions.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, vtt: vtt)) --> \(timestamp(cue.end, vtt: vtt))\n\(cue.text)\n"
        }.joined(separator: "\n")
        return (vtt ? "WEBVTT\n\n" : "") + body
    }
    public static func timestamp(_ seconds: Double, vtt: Bool = false) -> String {
        let ms = Int((max(0, min(seconds.isFinite ? seconds : 0, 1e9)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, vtt ? "." : ",", ms % 1000)
    }
    public static func decode(_ text: String) throws -> [TranscriptSegment] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var result: [TranscriptSegment] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let lineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[lineIndex].components(separatedBy: "-->")
            guard times.count == 2, let start = parseTime(times[0]), let end = parseTime(times[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else { throw EditError.invalid("Malformed subtitle timestamp.") }
            let words = lines.dropFirst(lineIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            let segment = TranscriptSegment(start: start, end: end, text: words)
            try segment.validate(); result.append(segment)
        }
        guard !result.isEmpty else { throw EditError.invalid("No readable SRT or WebVTT captions were found.") }
        return result.sorted { $0.start < $1.start }
    }
    private static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }), values.last! < 60, values[values.count - 2] < 60 else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }
}
