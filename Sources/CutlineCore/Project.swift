import Foundation

public enum CanvasFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape, portrait, square
    public var id: String { rawValue }
    public var label: String {
        switch self { case .landscape: return "16:9"; case .portrait: return "9:16"; case .square: return "1:1" }
    }
    public var size: CGSize {
        switch self {
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

public struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var duration: Double
    public var audioTrackCount: Int?
    public var displayName: String?
    public var name: String { displayName ?? url.deletingPathExtension().lastPathComponent }
    public init(id: UUID = UUID(), url: URL, duration: Double) {
        self.id = id; self.url = url; self.duration = duration
    }
}

public struct TimelineClip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var mediaID: UUID
    public var sourceIn: Double
    public var sourceOut: Double
    public var volume: Double
    public var adjustments: ClipAdjustments?
    public var speed: Double { adjustments?.speed ?? 1 }
    public var duration: Double { (sourceOut - sourceIn) / speed }
    public init(id: UUID = UUID(), mediaID: UUID, sourceIn: Double = 0, sourceOut: Double, volume: Double = 1) {
        self.id = id; self.mediaID = mediaID; self.sourceIn = sourceIn
        self.sourceOut = sourceOut; self.volume = volume
    }
}

public struct EditProject: Codable, Equatable, Sendable {
    public var version = 2
    public var name = "Untitled project"
    public var format: CanvasFormat = .landscape
    public var media: [MediaItem] = []
    public var clips: [TimelineClip] = []
    public var settings: ProjectSettings?
    public var captionTrack: CaptionTrack?
    public var transcripts: [SourceTranscript]?
    public var markers: [HighlightMarker]?
    public var overlays: [OverlayClip]?
    public var music: [AudioClip]?
    public var options: ProjectSettings { get { settings ?? ProjectSettings() } set { settings = newValue } }
    public var duration: Double { clips.reduce(0) { $0 + $1.duration } }
    public init() {}
    public func start(of id: UUID) -> Double {
        var time = 0.0
        for clip in clips { if clip.id == id { return time }; time += clip.duration }
        return time
    }
    public mutating func split(at time: Double) -> UUID? {
        var start = 0.0
        for index in clips.indices {
            let clip = clips[index]
            let offset = time - start
            if offset >= 0.1 && offset <= clip.duration - 0.1 {
                var right = clip
                right.id = UUID(); right.sourceIn = clip.sourceIn + offset * clip.speed
                clips[index].sourceOut = right.sourceIn
                clips.insert(right, at: index + 1)
                copyCaptions(from: clip.id, to: right.id)
                if markers != nil {
                    for markerIndex in markers!.indices where markers![markerIndex].clipID == clip.id && markers![markerIndex].sourceTime >= right.sourceIn { markers![markerIndex].clipID = right.id }
                }
                return right.id
            }
            start += clip.duration
        }
        return nil
    }
    public func validate() throws {
        guard (1...2).contains(version) else { throw EditError.invalid("This project uses an unsupported format version.") }
        guard Set(media.map(\.id)).count == media.count, Set(clips.map(\.id)).count == clips.count else {
            throw EditError.invalid("The project contains duplicate identifiers.")
        }
        try validateExtras()
        for item in media {
            guard item.url.isFileURL, item.duration.isFinite, item.duration >= 0.1 else {
                throw EditError.invalid("Invalid media metadata in this project.")
            }
        }
        for clip in clips {
            guard let item = media.first(where: { $0.id == clip.mediaID }),
                  clip.sourceIn.isFinite, clip.sourceOut.isFinite, clip.volume.isFinite,
                  clip.sourceIn >= 0, clip.duration >= 0.01,
                  clip.sourceOut <= item.duration + 0.001, (0...2).contains(clip.volume) else {
                throw EditError.invalid("The project contains an invalid clip range or media reference.")
            }
        }
    }
    public static func read(from url: URL) throws -> EditProject {
        var project = try JSONDecoder().decode(EditProject.self, from: Data(contentsOf: url))
        try project.validate()
        project.version = 2
        return project
    }
    public func write(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum EditError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public func timecode(_ seconds: Double) -> String {
    let safe = seconds.isFinite ? max(0, seconds) : 0
    let total = Int(safe * 100)
    return String(format: "%02d:%02d.%02d", total / 6000, total / 100 % 60, total % 100)
}
