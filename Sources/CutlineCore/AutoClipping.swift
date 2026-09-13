import Foundation

/// Coordinates are fractions of the displayed source frame, measured from its top-left.
public struct ClipScanRegion: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= 0.02 && height >= 0.02 && x + width <= 1.000001 && y + height <= 1.000001 }
}

public enum ClipGame: String, Codable, CaseIterable, Identifiable, Sendable {
    case generic, valorant, cs2, siege, wardogs, tarkov
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .generic: return "Any game"
        case .valorant: return "Valorant"
        case .cs2: return "Counter-Strike 2"
        case .siege: return "Rainbow Six Siege"
        case .wardogs: return "WARDOGS"
        case .tarkov: return "Escape from Tarkov"
        }
    }
    public var hasFeedPreset: Bool { [.valorant, .cs2, .siege].contains(self) }
}

public struct AutoClipSettings: Codable, Equatable, Sendable {
    public var game: ClipGame = .generic
    public var audioEnabled = true
    public var visionEnabled = true
    public var requireBoth = true
    /// Zero-based index into the source's audio tracks, never an implicit mix.
    public var audioTrack = 0
    public var outputAudioTrack = 0
    public var audioRiseDB = 8.0
    public var audioFloorDB = -35.0
    public var motionThreshold = 0.07
    public var sampleFPS = 2.0
    public var lead = 6.0
    public var tail = 4.0
    public var encounterGap = 12.0
    public var maxDuration = 60.0
    public var maxClips = 20
    public var useOCR = false
    public var minimumKills = 2
    public var aliases = ""
    public var hudCalibrated = false
    public var hud = ClipScanRegion(x: 0.55, y: 0.02, width: 0.45, height: 0.3)
    public var motionRegion = ClipScanRegion(x: 0.05, y: 0.15, width: 0.8, height: 0.7)
    public init() {}
    public static func preset(_ game: ClipGame) -> Self {
        var s = Self(); s.game = game
        if game == .siege { s.lead = 8; s.tail = 4; s.encounterGap = 15 }
        if game == .wardogs { s.lead = 10; s.tail = 5; s.encounterGap = 20 }
        if game == .tarkov { s.lead = 15; s.tail = 8; s.encounterGap = 25 }
        return s
    }
    public func validate() throws {
        guard audioEnabled || visionEnabled || useOCR else { throw EditError.invalid("Enable audio, frame changes, or HUD OCR.") }
        guard audioTrack >= 0, audioTrack < 64, outputAudioTrack >= 0, outputAudioTrack < 64, (1...5).contains(sampleFPS), (3...30).contains(audioRiseDB), (-80...0).contains(audioFloorDB),
              (0.01...0.4).contains(motionThreshold), (0...30).contains(lead), (0...30).contains(tail),
              (1...30).contains(encounterGap), (3...180).contains(maxDuration), lead + tail < maxDuration,
              (1...100).contains(maxClips), (1...10).contains(minimumKills), hud.valid, motionRegion.valid else {
            throw EditError.invalid("Check scan thresholds, regions, and clip lengths. Setup plus payoff must be shorter than the maximum clip.")
        }
        if useOCR && (!hudCalibrated || playerNames.isEmpty || aliases.count > 500) {
            throw EditError.invalid("Set your player aliases and confirm the HUD region before enabling OCR.")
        }
    }
    public var playerNames: [String] { aliases.components(separatedBy: CharacterSet(charactersIn: ",\n")).map(Self.normalizeName).filter { !$0.isEmpty && $0 != "you" } }
    public static func normalizeName(_ name: String) -> String { name.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

public struct ClipAudioSample: Codable, Equatable, Sendable {
    public var time: Double, db: Double
    public init(time: Double, db: Double) { self.time = time; self.db = db }
}
public struct ClipMotionSample: Codable, Equatable, Sendable {
    public var time: Double, change: Double
    public var sceneCut: Bool
    public init(time: Double, change: Double, sceneCut: Bool = false) { self.time = time; self.change = change; self.sceneCut = sceneCut }
}
public enum ClipSignal: String, Codable, Sendable { case audio, motion, elimination, death, marker }
public struct ClipEvidence: Codable, Equatable, Sendable {
    public var time: Double
    public var signal: ClipSignal
    public var strength: Double
    public var detail: String
    public init(time: Double, signal: ClipSignal, strength: Double = 1, detail: String) {
        self.time = time; self.signal = signal; self.strength = strength; self.detail = detail
    }
}
public struct AutoClipCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double, end: Double, score: Double
    public var evidence: [ClipEvidence]
    public init(id: String, start: Double, end: Double, score: Double, evidence: [ClipEvidence]) {
        self.id = id; self.start = start; self.end = end; self.score = score; self.evidence = evidence
    }
    public var title: String {
        let kills = evidence.filter { $0.signal == .elimination }.count
        return kills > 0 ? "\(kills) HUD elimination match\(kills == 1 ? "" : "es")" : evidence.contains { $0.signal == .marker } ? "Marked moment" : "Activity at \(timecode(evidence.first?.time ?? start))"
    }
}
public struct AutoClipReport: Codable, Equatable, Sendable {
    public var media: MediaItem
    public var settings: AutoClipSettings
    public var candidates: [AutoClipCandidate]
    public var evidence: [ClipEvidence]
    public var audioSamples: [ClipAudioSample]
    public var motionSamples: [ClipMotionSample]
    public var warnings: [String]
    public var sampledFrames: Int
    public var ocrReads: Int
    public init(media: MediaItem, settings: AutoClipSettings, candidates: [AutoClipCandidate], evidence: [ClipEvidence], audioSamples: [ClipAudioSample] = [], motionSamples: [ClipMotionSample] = [], warnings: [String] = [], sampledFrames: Int = 0, ocrReads: Int = 0) {
        self.media = media; self.settings = settings; self.candidates = candidates; self.evidence = evidence; self.audioSamples = audioSamples; self.motionSamples = motionSamples; self.warnings = warnings; self.sampledFrames = sampledFrames; self.ocrReads = ocrReads
    }
}

public enum AutoClipRules {
    public static func audioEvents(_ samples: [ClipAudioSample], settings: AutoClipSettings) -> [ClipEvidence] {
        let samples = samples.filter { $0.time.isFinite && $0.db.isFinite }.sorted { $0.time < $1.time }
        var result: [ClipEvidence] = []
        var low = 0, high = 0
        for (i, sample) in samples.enumerated() {
            while low < i && samples[low].time < sample.time - 15 { low += 1 }
            while high < samples.count && samples[high].time <= sample.time + 15 { high += 1 }
            let values = samples[low..<high].map(\.db).sorted()
            guard values.count >= 4 else { continue }
            let baseline = values[values.count / 2]
            let rise = sample.db - baseline
            guard sample.db >= settings.audioFloorDB, rise >= settings.audioRiseDB else { continue }
            let e = ClipEvidence(time: sample.time, signal: .audio, strength: min(1, rise / 24), detail: String(format: "Track %d: %.1f dBFS, %.1f dB above local median", settings.audioTrack + 1, sample.db, rise))
            // Keep the strongest sample in each short burst rather than every PCM window.
            if let last = result.last, sample.time - last.time <= 1 {
                if e.strength > last.strength { result[result.count - 1] = e }
            } else { result.append(e) }
        }
        return result
    }
    public static func motionEvents(_ samples: [ClipMotionSample], settings: AutoClipSettings) -> [ClipEvidence] {
        var events: [ClipEvidence] = []
        for i in samples.indices where i > 0 {
            let s = samples[i], p = samples[i - 1]
            guard s.time.isFinite, s.change.isFinite, !s.sceneCut, !p.sceneCut,
                  s.time > p.time, s.time - p.time <= 1.6 / settings.sampleFPS,
                  s.change >= settings.motionThreshold, p.change >= settings.motionThreshold else { continue }
            if let last = events.last, s.time - last.time < 1 { continue }
            events.append(ClipEvidence(time: s.time, signal: .motion, strength: min(1, s.change / 0.25), detail: String(format: "Sustained frame change: %.1f%% of luminance range", s.change * 100)))
        }
        return events
    }
    /// Never invent a semantic event from pixels or loudness. Scores rank measured activity only.
    public static func candidates(evidence: [ClipEvidence], duration: Double, settings: AutoClipSettings) -> [AutoClipCandidate] {
        guard duration.isFinite, duration > 0 else { return [] }
        let all = evidence.filter { $0.time.isFinite && $0.strength.isFinite && $0.time >= 0 && $0.time < duration }.sorted { $0.time == $1.time ? $0.signal.rawValue < $1.signal.rawValue : $0.time < $1.time }
        let audio = all.filter { $0.signal == .audio }, motion = all.filter { $0.signal == .motion }
        let eligible = all.filter { e in
            if e.signal == .elimination || e.signal == .death || e.signal == .marker { return true }
            if settings.requireBoth && settings.audioEnabled && settings.visionEnabled {
                return nearby(e.time, in: e.signal == .audio ? motion : audio)
            }
            return (e.signal == .audio && settings.audioEnabled) || (e.signal == .motion && settings.visionEnabled)
        }
        var groups: [[ClipEvidence]] = [], group: [ClipEvidence] = []
        var boundaries: [Double] = [0, duration]
        for e in eligible {
            if e.signal == .death { if !group.isEmpty { groups.append(group); group = [] }; boundaries.append(e.time); continue }
            if let first = group.first, let last = group.last,
               e.time - last.time > settings.encounterGap || e.time - first.time + settings.lead + max(0.5, settings.tail) > settings.maxDuration {
                groups.append(group); group = []
            }
            group.append(e)
        }
        if !group.isEmpty { groups.append(group) }
        let proposals: [AutoClipCandidate] = groups.compactMap { events -> AutoClipCandidate? in
            let kills = events.filter { $0.signal == .elimination }.count
            guard kills >= settings.minimumKills || events.contains(where: { $0.signal != .elimination }) else { return nil }
            let first = events.first!.time, last = events.last!.time
            let lower = boundaries.filter { $0 <= first }.max() ?? 0
            let upper = boundaries.filter { $0 > last }.min() ?? duration
            let start = max(lower, first - settings.lead)
            let end = min(upper, last + max(0.5, settings.tail), start + settings.maxDuration)
            guard end - start >= 0.1 else { return nil }
            let audioScore = (events.filter { $0.signal == .audio }.map(\.strength).max() ?? 0) * 30
            let motionScore = (events.filter { $0.signal == .motion }.map(\.strength).max() ?? 0) * 20
            let markerScore = events.contains { $0.signal == .marker } ? 60.0 : 0.0
            let score = min(100, Double(kills) * 20 + markerScore + audioScore + motionScore)
            return AutoClipCandidate(id: String(format: "%.3f-%.3f", start, end), start: start, end: end, score: score, evidence: events)
        }.sorted { $0.score == $1.score ? $0.start < $1.start : $0.score > $1.score }
        // Suppress duplicate padded windows. Never publish overlapping copies of one encounter.
        var selected: [AutoClipCandidate] = []
        for proposal in proposals {
            guard !selected.contains(where: { min($0.end, proposal.end) - max($0.start, proposal.start) > 0 }) else { continue }
            selected.append(proposal)
            if selected.count >= settings.maxClips { break }
        }
        return selected.sorted { $0.start < $1.start }
    }
    private static func nearby(_ time: Double, in events: [ClipEvidence]) -> Bool {
        var low = 0, high = events.count
        while low < high { let mid = (low + high) / 2; if events[mid].time < time - 2 { low = mid + 1 } else { high = mid } }
        return low < events.count && events[low].time <= time + 2
    }
    public static func project(for candidate: AutoClipCandidate, media: MediaItem, outputAudioTrack: Int = 0) throws -> EditProject {
        guard candidate.start.isFinite, candidate.end.isFinite, candidate.start >= 0, candidate.end <= media.duration, candidate.end > candidate.start else { throw EditError.invalid("Invalid automatic clip range.") }
        guard (0..<64).contains(outputAudioTrack), outputAudioTrack < max(1, media.audioTrackCount ?? 64) else { throw EditError.invalid("Choose an available export audio track.") }
        var project = EditProject(); project.name = candidate.title; project.media = [media]
        project.clips = [TimelineClip(mediaID: media.id, sourceIn: candidate.start, sourceOut: candidate.end)]
        var adjustments = ClipAdjustments()
        // OBS audience mix and isolated tracks often contain the same sound. Export exactly one.
        adjustments.audioGains = Dictionary(uniqueKeysWithValues: (0..<max(1, media.audioTrackCount ?? 64)).map { (String($0), $0 == outputAudioTrack ? 1.0 : 0.0) })
        project.clips[0].adjustments = adjustments
        try project.validate(); return project
    }
}
