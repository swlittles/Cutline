import Foundation

/// Everything said in a recording, with timestamps, kept beside its scan measurements.
/// Finding moments by what was said needs the whole stream, so this is made once per
/// recording and speech track and reused across sessions.
public struct StreamTranscript: Codable, Equatable, Sendable {
    public var audioTrack: Int
    /// "whisper.base", "apple" and so on. A different engine makes a new transcript.
    public var engine: String
    public var segments: [TranscriptSegment]
    public init(audioTrack: Int, engine: String, segments: [TranscriptSegment]) {
        self.audioTrack = audioTrack; self.engine = engine; self.segments = segments
    }
    /// Drops what speech engines invent over music and silence: lines with no words, and the same
    /// line coming back more than twice within a minute.
    public static func withoutLoops(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var recent: [(time: Double, text: String)] = []
        return segments.sorted { $0.start < $1.start }.filter { segment in
            let text = segment.text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return false }
            recent.removeAll { segment.start - $0.time > 60 }
            let seen = recent.filter { $0.text == text }.count
            recent.append((segment.start, text))
            return seen < 2
        }
    }
    /// Speech inside a range, for showing what was said in a moment.
    public func text(from start: Double, to end: Double) -> String {
        segments.filter { $0.end > start && $0.start < end }.map(\.text).joined(separator: " ")
    }
    /// Caption lines for one clip, trimmed to its range.
    public func captions(from start: Double, to end: Double) -> [TranscriptSegment] {
        segments.compactMap { segment in
            let low = max(start, segment.start), high = min(end, segment.end)
            return high - low >= 0.05 ? TranscriptSegment(start: low, end: high, text: segment.text) : nil
        }
    }
}

public enum StreamTranscriptCache {
    static func url(for media: MediaItem, track: Int, root: URL) -> URL? {
        ClipAnalysisCache.key(for: media).map { root.appendingPathComponent("Transcripts", isDirectory: true).appendingPathComponent("\($0)-track\(track).json") }
    }
    public static func load(for media: MediaItem, track: Int, root: URL = LocalTools.support) -> StreamTranscript? {
        guard let url = url(for: media, track: track, root: root), let data = try? Data(contentsOf: url),
              let transcript = try? JSONDecoder().decode(StreamTranscript.self, from: data), transcript.audioTrack == track else { return nil }
        return transcript
    }
    public static func save(_ transcript: StreamTranscript, for media: MediaItem, root: URL = LocalTools.support) throws {
        guard let target = url(for: media, track: transcript.audioTrack, root: root) else { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(transcript).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
