import Foundation

/// What an embedded OBS track carries. Roles decide which track detects moments,
/// which tracks play in exported clips, and which track captions listen to.
public enum AudioRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case mix, mic, game, ignore
    public var id: String { rawValue }
    public var label: String {
        switch self { case .mix: return "Full mix"; case .mic: return "Mic"; case .game: return "Game"; case .ignore: return "Ignore" }
    }
    /// A starting point only: OBS track layouts vary, so the setup step asks the user to confirm.
    public static func guess(count: Int, names: [String?] = []) -> [AudioRole] {
        (0..<max(0, count)).map { index in
            let name = (index < names.count ? names[index] : nil)?.lowercased() ?? ""
            if ["mic", "voice", "commentary"].contains(where: name.contains) { return .mic }
            if ["game", "desktop"].contains(where: name.contains) { return .game }
            if ["mix", "stream", "all", "master"].contains(where: name.contains) { return .mix }
            if count == 1 { return .mix }
            return [.mix, .mic, .game][safe: index] ?? .ignore
        }
    }
}

public struct AudioRoutes: Equatable, Sendable {
    public var detect: Int
    public var export: [Int]
    public var speech: Int
    public init(_ roles: [AudioRole]) {
        let indices = { (role: AudioRole) in roles.indices.filter { roles[$0] == role } }
        let mixes = indices(.mix), mics = indices(.mic), games = indices(.game)
        // A full mix already contains mic and game. Adding isolated tracks to it doubles them.
        export = !mixes.isEmpty ? [mixes[0]] : !(mics + games).isEmpty ? (mics + games).sorted() : [0]
        detect = mics.first ?? games.first ?? mixes.first ?? 0
        speech = mics.first ?? mixes.first ?? 0
    }
}

/// A saved OBS layout: crops, audio roles, game and activity area, reused across recordings.
public struct ScenePreset: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var framing: ShortFraming
    public var audioRoles: [AudioRole]
    public var game: ClipGame
    public var motionRegion: ClipScanRegion
    public init(name: String, framing: ShortFraming, audioRoles: [AudioRole], game: ClipGame, motionRegion: ClipScanRegion) {
        self.name = name; self.framing = framing; self.audioRoles = audioRoles; self.game = game; self.motionRegion = motionRegion
    }
    public func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, name.count <= 60, !name.contains(where: \.isNewline), motionRegion.valid, audioRoles.count <= 64 else {
            throw EditError.invalid("Name the scene preset (1–60 characters) and keep its regions inside the frame.")
        }
        try framing.validate()
    }
    /// Crops were confirmed when the preset was saved; choosing it for a recording confirms them again.
    public func apply(to media: inout MediaItem) {
        var framing = framing; framing.confirmed = true
        media.shortFraming = framing
        let count = media.audioTrackCount ?? audioRoles.count
        media.audioRoles = (0..<count).map { audioRoles[safe: $0] ?? .ignore }
    }
}

public enum ScenePresetStore {
    public static func load(from root: URL = LocalTools.support) throws -> [ScenePreset] {
        let url = root.appendingPathComponent("scene-presets.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let presets = try JSONDecoder().decode([ScenePreset].self, from: Data(contentsOf: url))
        for preset in presets { try preset.validate() }
        return presets
    }
    public static func save(_ presets: [ScenePreset], to root: URL = LocalTools.support) throws {
        for preset in presets { try preset.validate() }
        guard Set(presets.map(\.id)).count == presets.count, presets.count <= 100 else { throw EditError.invalid("Scene presets must be unique (up to 100).") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("scene-presets.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}

public struct ClipRange: Codable, Equatable, Sendable {
    public var start: Double, end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public enum ClipDecision: Equatable, Sendable { case undecided, kept, skipped }

/// Review decisions for one recording's moments, keyed by candidate identifier.
/// Stored in the project so a session can be saved, recovered and resumed.
public struct ClipReview: Codable, Equatable, Sendable {
    public static let minimumLength = 1.0
    public static let maximumLength = 180.0
    public var mediaID: UUID
    public var kept: [String] = []
    public var skipped: [String] = []
    public var ranges: [String: ClipRange] = [:]
    /// Moments marked by hand, in source seconds.
    public var moments: [Double] = []
    public var captionsEnabled = false
    /// Transcribed speech for kept clips only, in source seconds.
    public var captions: [String: [TranscriptSegment]] = [:]
    public init(mediaID: UUID) { self.mediaID = mediaID }

    enum CodingKeys: String, CodingKey { case mediaID, kept, skipped, ranges, moments, captionsEnabled, captions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = try c.decode(UUID.self, forKey: .mediaID)
        kept = try c.decodeIfPresent([String].self, forKey: .kept) ?? []
        skipped = try c.decodeIfPresent([String].self, forKey: .skipped) ?? []
        ranges = try c.decodeIfPresent([String: ClipRange].self, forKey: .ranges) ?? [:]
        moments = try c.decodeIfPresent([Double].self, forKey: .moments) ?? []
        captionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .captionsEnabled) ?? false
        captions = try c.decodeIfPresent([String: [TranscriptSegment]].self, forKey: .captions) ?? [:]
    }

    public func decision(_ id: String) -> ClipDecision { kept.contains(id) ? .kept : skipped.contains(id) ? .skipped : .undecided }
    public mutating func decide(_ id: String, _ decision: ClipDecision) {
        kept.removeAll { $0 == id }; skipped.removeAll { $0 == id }
        switch decision { case .kept: kept.append(id); case .skipped: skipped.append(id); case .undecided: break }
    }
    /// The candidate with any user trim applied. Identity stays with the detected moment.
    public func applied(_ candidate: AutoClipCandidate) -> AutoClipCandidate {
        guard let range = ranges[candidate.id] else { return candidate }
        var copy = candidate; copy.start = range.start; copy.end = range.end; return copy
    }
    public mutating func setRange(_ id: String, start: Double, end: Double, duration: Double) {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0 else { return }
        let length = min(Self.maximumLength, max(min(Self.minimumLength, duration), end - start))
        var low = max(0, min(start, duration - length))
        let high = min(duration, low + length)
        low = max(0, high - length)
        ranges[id] = ClipRange(start: low, end: high)
        captions[id] = nil
    }
    public mutating func addMoment(_ time: Double, duration: Double) {
        guard time.isFinite, time >= 0, time < duration, !moments.contains(where: { abs($0 - time) < 0.5 }), moments.count < 500 else { return }
        moments.append(time); moments.sort()
    }
    public func validate(duration: Double?) throws {
        let limit = duration ?? .infinity
        for range in ranges.values {
            guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end > range.start, range.end <= limit + 0.001 else { throw EditError.invalid("A reviewed clip has an invalid range.") }
        }
        guard moments.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= limit }) else { throw EditError.invalid("A marked moment is outside its recording.") }
        for segments in captions.values { for segment in segments { try segment.validate(); guard segment.end <= limit + 0.01 else { throw EditError.invalid("A clip caption exceeds its recording.") } } }
    }
}

public extension AutoClipSettings {
    /// One control for how many moments to find: 0 = fewer, stronger; 1 = more, looser.
    /// The midpoint reproduces the default thresholds exactly.
    var sensitivity: Double {
        get { audioRiseDB >= 8 ? max(0, min(0.5, (12 - audioRiseDB) / 8)) : max(0.5, min(1, 0.5 + (8 - audioRiseDB) / 6)) }
        set {
            let s = max(0, min(1, newValue.isFinite ? newValue : 0.5))
            func round(_ v: Double, _ places: Double) -> Double { (v * places).rounded() / places }
            if s <= 0.5 {
                audioRiseDB = round(12 - 8 * s, 10); audioFloorDB = round(-30 - 10 * s, 10); motionThreshold = round(0.10 - 0.06 * s, 1000)
            } else {
                let t = s - 0.5
                audioRiseDB = round(8 - 6 * t, 10); audioFloorDB = round(-35 - 20 * t, 10); motionThreshold = round(0.07 - 0.06 * t, 1000)
            }
        }
    }
}

/// Starting points for a hook. The user always chooses or edits the text that ships.
public enum HookIdeas {
    public static func suggestions(for candidate: AutoClipCandidate, game: ClipGame) -> [String] {
        let kills = candidate.evidence.filter { $0.signal == .elimination }.count
        let seconds = Int((candidate.end - candidate.start).rounded())
        var ideas: [String] = []
        if kills >= 2 { ideas.append("\(kills) kills in \(seconds) seconds") }
        if candidate.evidence.contains(where: { $0.signal == .audio && $0.strength > 0.6 }) { ideas.append("I was NOT ready for this") }
        ideas += ["Wait for it…", "Chat, did you see that?", "This is why I play \(game == .generic ? "this game" : game.label)", "Would you have made this play?"]
        return Array(ideas.prefix(5))
    }
}

/// Hours-aware clock for long recordings, e.g. 1:02:10 or 4:05.
public func clockTime(_ seconds: Double) -> String {
    let total = Int((seconds.isFinite ? max(0, seconds) : 0).rounded(.down))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
