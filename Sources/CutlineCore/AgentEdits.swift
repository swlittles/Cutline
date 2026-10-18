import Foundation

/// Paths from agents may be absolute, relative to the agent's folder, or start with `~`.
public enum AgentPaths {
    public static func url(_ path: String, directory: Bool = false) -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, isDirectory: directory, relativeTo: expanded.hasPrefix("/") ? nil : base).standardizedFileURL
    }
    public static func looksLikePath(_ value: String) -> Bool { value.contains("/") || value.hasPrefix("~") || value.contains(".") }
}

/// Applies a list of agent edits to a project. All or nothing: any invalid change leaves the
/// project untouched. Videos and music named by path are inspected ahead of time by the caller.
public struct AgentEditor {
    public var videos: [String: MediaItem] = [:]
    public var music: [String: Double] = [:]
    public var presets: [ScenePreset] = []
    public init(videos: [String: MediaItem] = [:], music: [String: Double] = [:], presets: [ScenePreset] = []) {
        self.videos = videos; self.music = music; self.presets = presets
    }

    public static let operations = ["add_video", "add_clip", "remove_clip", "trim_clip", "move_clip", "split", "set_volume", "set_track_volume", "set_speed",
                                    "set_hook", "set_clip_hook", "set_format", "set_layout", "keep_range", "cut_range", "add_captions", "clear_captions",
                                    "set_caption_text", "set_caption_style", "set_captions_burned", "add_music", "set_quality", "rename"]

    /// Paths the operations mention that may need importing first.
    public static func referencedPaths(_ operations: [JSON]) -> (videos: [String], music: [String]) {
        var videos: [String] = [], music: [String] = []
        for operation in operations {
            switch operation["op"]?.string {
            case "add_video": if let path = operation["path"]?.string { videos.append(path) }
            case "add_clip", "set_layout": if let path = operation["video"]?.string, AgentPaths.looksLikePath(path), UUID(uuidString: path) == nil { videos.append(path) }
            case "add_music": if let path = operation["path"]?.string { music.append(path) }
            default: break
            }
        }
        return (videos, music)
    }

    /// Returns one plain sentence per change.
    @discardableResult public func apply(_ operations: [JSON], to project: inout EditProject) throws -> [String] {
        guard !operations.isEmpty else { throw EditError.invalid("List at least one change in operations.") }
        guard operations.count <= 200 else { throw EditError.invalid("Send at most 200 changes at a time.") }
        var draft = project, notes: [String] = []
        for (index, operation) in operations.enumerated() {
            let name = operation["op"]?.string ?? ""
            do {
                guard Self.operations.contains(name) else {
                    throw EditError.invalid("Unknown op “\(name)”. Use one of: \(Self.operations.joined(separator: ", ")).")
                }
                notes.append(try apply(name, Arguments(operation), to: &draft))
            } catch {
                throw EditError.invalid("Change \(index + 1) (\(name.isEmpty ? "missing op" : name)): \(error.localizedDescription) Nothing was changed.")
            }
        }
        do { try draft.validate() } catch { throw EditError.invalid("\(error.localizedDescription) Nothing was changed.") }
        project = draft
        return notes
    }

    private func apply(_ op: String, _ a: Arguments, to p: inout EditProject) throws -> String {
        switch op {
        case "add_video":
            let media = try video(a.value("path"), in: &p)
            return "Added video \(media.name)."
        case "add_clip":
            let media = try video(a.value("video"), in: &p)
            let start = try a.number("start", default: 0), end = min(try a.number("end", default: media.duration), media.duration)
            try checkRange(start, end, within: media)
            var clip = TimelineClip(mediaID: media.id, sourceIn: start, sourceOut: end, volume: try a.number("volume", default: 1, in: 0...2))
            if let roles = media.audioRoles, roles.count > 1 {
                // A full mix already contains mic and game: play only the routed tracks.
                let export = AudioRoutes(roles).export
                var adjustments = ClipAdjustments()
                adjustments.audioGains = Dictionary(uniqueKeysWithValues: roles.indices.map { (String($0), export.contains($0) ? 1.0 : 0.0) })
                clip.adjustments = adjustments
            }
            let position = try a.position("position", count: p.clips.count + 1) ?? p.clips.count
            p.clips.insert(clip, at: position)
            return "Added clip \(position + 1): \(media.name) \(clockTime(start))–\(clockTime(end)) (\(seconds(clip.duration)))."
        case "remove_clip":
            let i = try clip(a, in: p)
            p.removeClip(p.clips[i].id)
            return "Removed clip \(i + 1)."
        case "trim_clip":
            let i = try clip(a, in: p)
            guard let media = p.media.first(where: { $0.id == p.clips[i].mediaID }) else { throw EditError.invalid("Clip \(i + 1) has no video.") }
            // An end past the video means "to the end".
            let start = try a.number("start", default: p.clips[i].sourceIn), end = min(try a.number("end", default: p.clips[i].sourceOut), media.duration)
            try checkRange(start, end, within: media)
            p.clips[i].sourceIn = start; p.clips[i].sourceOut = end
            return "Clip \(i + 1) now plays \(clockTime(start))–\(clockTime(end)) of \(media.name)."
        case "move_clip":
            let i = try clip(a, in: p)
            guard let target = try a.position("position", count: p.clips.count) else { throw EditError.invalid("Give the new position (1 = first).") }
            let moved = p.clips.remove(at: i); p.clips.insert(moved, at: target)
            return "Moved clip \(i + 1) to position \(target + 1)."
        case "split":
            let time = try a.number("time")
            guard p.split(at: time) != nil else { throw EditError.invalid("Can’t split at \(seconds(time)): choose a time at least 0.1 s inside a clip (the timeline is \(seconds(p.duration)) long).") }
            return "Split the timeline at \(seconds(time))."
        case "set_volume":
            let i = try clip(a, in: p)
            p.clips[i].volume = try a.number("volume", in: 0...2)
            return "Clip \(i + 1) volume is \(Int(p.clips[i].volume * 100))%."
        case "set_track_volume":
            let i = try clip(a, in: p)
            let track = Int(try a.number("track", in: 1...64))
            let tracks = p.media.first { $0.id == p.clips[i].mediaID }?.audioTrackCount ?? 0
            guard track <= tracks else { throw EditError.invalid("That video has \(tracks) audio track\(tracks == 1 ? "" : "s").") }
            var adjustments = p.clips[i].adjustments ?? ClipAdjustments()
            adjustments.audioGains[String(track - 1)] = try a.number("volume", in: 0...2)
            p.clips[i].adjustments = adjustments
            return "Clip \(i + 1) audio track \(track) is \(Int((adjustments.audioGains[String(track - 1)] ?? 1) * 100))%."
        case "set_speed":
            let i = try clip(a, in: p)
            var adjustments = p.clips[i].adjustments ?? ClipAdjustments()
            adjustments.speed = try a.number("speed", in: 0.25...4)
            p.clips[i].adjustments = adjustments
            return "Clip \(i + 1) plays at \(adjustments.speed)×."
        case "set_hook":
            let text = try hook(a.optionalString("text"))
            p.shortHook = text
            return text == nil ? "Removed the shared hook." : "Hook for every clip: “\(text!)”."
        case "set_clip_hook":
            let i = try clip(a, in: p)
            p.clips[i].shortHook = try hook(a.optionalString("text"))
            return p.clips[i].shortHook.map { "Clip \(i + 1) hook: “\($0)”." } ?? "Clip \(i + 1) uses the shared hook."
        case "set_format":
            switch try a.string("format") {
            case "short": p.selectWorkflow(.mobileShort); return "Format: vertical short (9:16)."
            case "youtube": p.selectWorkflow(.youtubeVideo); return "Format: YouTube video (16:9)."
            default: throw EditError.invalid("format is short or youtube.")
            }
        case "set_layout":
            let target = try video(a.value("video") ?? (p.media.count == 1 ? JSON(1) : nil), in: &p)
            guard let index = p.media.firstIndex(where: { $0.id == target.id }) else { throw EditError.invalid("Unknown video.") }
            if let name = try a.optionalString("layout") {
                guard let preset = presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw EditError.invalid(presets.isEmpty ? "There are no saved layouts. Give facecam and gameplay boxes instead." : "No saved layout is called “\(name)”. Saved layouts: \(presets.map(\.name).joined(separator: ", ")).")
                }
                preset.apply(to: &p.media[index])
                return "\(target.name) uses the “\(preset.name)” layout."
            }
            var framing = p.media[index].shortFraming ?? ShortFraming()
            if let box = a.raw["facecam"] { framing.camera = try region(box, "facecam") }
            if let box = a.raw["gameplay"] { framing.gameplay = try region(box, "gameplay") }
            if let fit = a.raw["fit_gameplay"]?.bool { framing.containGameplay = fit }
            framing.confirmed = true
            try framing.validate()
            p.media[index].shortFraming = framing
            return "Set the facecam and gameplay areas for \(target.name)."
        case "keep_range":
            let start = try a.number("start"), end = try a.number("end")
            try p.keepTimelineRange(start: start, end: min(end, p.duration))
            return "Kept \(seconds(start))–\(seconds(end)); the timeline is now \(seconds(p.duration))."
        case "cut_range":
            let start = try a.number("start"), end = try a.number("end")
            guard start >= 0, end > start, start < p.duration else { throw EditError.invalid("Choose a range inside the timeline (0–\(seconds(p.duration))).") }
            try p.removeTimelineRanges([TimelineRange(start: start, end: min(end, p.duration))])
            return "Cut \(seconds(start))–\(seconds(end)); the timeline is now \(seconds(p.duration))."
        case "add_captions":
            guard let items = a.raw["captions"]?.array, !items.isEmpty else { throw EditError.invalid("Give captions as a list of {start, end, text} in timeline seconds.") }
            let segments = try items.map { item -> TranscriptSegment in
                let line = Arguments(item)
                let segment = TranscriptSegment(start: try line.number("start"), end: try line.number("end"), text: try line.string("text"))
                try segment.validate(); return segment
            }
            let before = p.captionTrack?.cues.count ?? 0
            p.importCaptions(segments)
            return "Added \((p.captionTrack?.cues.count ?? 0) - before) caption\(segments.count == 1 ? "" : "s")."
        case "clear_captions":
            p.captionTrack?.cues = []
            return "Removed all captions."
        case "set_caption_text":
            let id = try a.string("caption")
            guard let index = p.captionTrack?.cues.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else { throw EditError.invalid("No caption has id \(id). read_project lists caption ids.") }
            let text = try a.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { p.captionTrack?.cues.remove(at: index); return "Removed a caption." }
            p.captionTrack?.cues[index].text = text
            return "Caption now reads “\(text)”."
        case "set_caption_style":
            if p.captionTrack == nil { p.captionTrack = CaptionTrack() }
            var style = p.captionTrack!.style
            if a.raw["font_size"] != nil { style.fontSize = try a.number("font_size", in: 16...140) }
            if a.raw["position"] != nil { style.bottom = try a.number("position", in: 0.02...0.9) }
            if let value = a.raw["uppercase"]?.bool { style.uppercase = value }
            if let value = a.raw["background"]?.bool { style.background = value }
            if let value = try a.optionalString("color") {
                let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
                guard hex.count == 6, UInt32(hex, radix: 16) != nil else { throw EditError.invalid("color is a hex value such as FFFFFF.") }
                style.colorHex = hex
            }
            p.captionTrack?.style = style
            return "Updated the caption style."
        case "set_captions_burned":
            guard let on = a.raw["on"]?.bool else { throw EditError.invalid("Set on to true or false.") }
            p.options.burnCaptions = on
            return on ? "Captions are drawn into the video." : "Captions are not drawn into the video."
        case "add_music":
            let path = try a.string("path")
            guard let length = music[path] else { throw EditError.invalid("Couldn’t read the audio file \(path).") }
            var clip = AudioClip(url: AgentPaths.url(path), start: try a.number("start", default: 0), duration: length)
            clip.volume = try a.number("volume", default: 0.3, in: 0...2)
            clip.fadeIn = try a.number("fade_in", default: 1, in: 0...30); clip.fadeOut = try a.number("fade_out", default: 2, in: 0...30)
            guard clip.start >= 0 else { throw EditError.invalid("start can’t be negative.") }
            p.music = (p.music ?? []) + [clip]
            return "Added music \(clip.url.lastPathComponent) at \(Int(clip.volume * 100))% volume."
        case "set_quality":
            if a.raw["resolution"] != nil {
                let value = Int(try a.number("resolution"))
                guard [720, 1080, 2160].contains(value) else { throw EditError.invalid("resolution is 720, 1080 or 2160.") }
                p.options.resolution = value
            }
            if a.raw["fps"] != nil {
                let value = Int(try a.number("fps"))
                guard [24, 25, 30, 50, 60].contains(value) else { throw EditError.invalid("fps is 24, 25, 30, 50 or 60.") }
                p.options.fps = value
            }
            return "Quality: \(p.options.resolution)p at \(p.options.fps) fps."
        case "rename":
            let name = try a.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120 else { throw EditError.invalid("Use a name of 1–120 characters.") }
            p.name = name
            return "Renamed the project to \(name)."
        default:
            throw EditError.invalid("Unknown op.")
        }
    }

    private func clip(_ a: Arguments, in p: EditProject) throws -> Int {
        guard let value = a.raw["clip"] else { throw EditError.invalid("Say which clip: its number (1 = first on the timeline) or its id.") }
        if let number = value.number ?? value.string.flatMap(Double.init), number.rounded() == number, Int(number) >= 1, Int(number) <= p.clips.count { return Int(number) - 1 }
        if let id = value.string, let index = p.clips.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) { return index }
        throw EditError.invalid("There’s no clip \(value.text): the timeline has \(p.clips.count) clip\(p.clips.count == 1 ? "" : "s").")
    }
    /// A video by number, id or path. A new path joins the project's media.
    private func video(_ value: JSON?, in p: inout EditProject) throws -> MediaItem {
        guard let value else { throw EditError.invalid("Say which video: its number, id or file path.") }
        if let number = value.number, number.rounded() == number, Int(number) >= 1, Int(number) <= p.media.count { return p.media[Int(number) - 1] }
        guard let text = value.string else { throw EditError.invalid("There’s no video \(value.text): the project has \(p.media.count).") }
        if let media = p.media.first(where: { $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame }) { return media }
        if let number = Int(text), number >= 1, number <= p.media.count { return p.media[number - 1] }
        guard let inspected = videos[text] else { throw EditError.invalid("Couldn’t open the video \(text).") }
        if let existing = p.media.first(where: { $0.url.standardizedFileURL == inspected.url.standardizedFileURL }) { return existing }
        p.media.append(inspected)
        return inspected
    }
    private func checkRange(_ start: Double, _ end: Double, within media: MediaItem) throws {
        guard start >= 0, end > start, start < media.duration else {
            throw EditError.invalid("Choose start and end seconds inside \(media.name) (0–\(seconds(media.duration))) with end after start.")
        }
        guard end - start >= 0.1 else { throw EditError.invalid("A clip must be at least 0.1 seconds long.") }
    }
    private func hook(_ text: String?) throws -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.count <= 80, !text.contains(where: \.isNewline) else { throw EditError.invalid("A hook is one line of up to 80 characters.") }
        return text
    }
    private func region(_ box: JSON, _ name: String) throws -> ClipScanRegion {
        let b = Arguments(box)
        let region = ClipScanRegion(x: try b.number("x"), y: try b.number("y"), width: try b.number("width"), height: try b.number("height"))
        guard region.valid else { throw EditError.invalid("\(name) is {x, y, width, height} as fractions of the source frame from its top-left, inside 0–1.") }
        return region
    }
}

func seconds(_ value: Double) -> String { String(format: value.rounded() == value ? "%.0f s" : "%.2f s", value) }

/// Typed access to an agent's arguments with plain-language errors.
struct Arguments: Sendable {
    let raw: JSON
    init(_ raw: JSON) { self.raw = raw }
    func value(_ key: String) -> JSON? { raw[key].flatMap { $0.isNull ? nil : $0 } }
    func string(_ key: String) throws -> String {
        guard let value = raw[key]?.string else { throw EditError.invalid("\(key) is required (text).") }
        return value
    }
    func optionalString(_ key: String) throws -> String? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let text = value.string else { throw EditError.invalid("\(key) must be text.") }
        return text
    }
    func number(_ key: String, default fallback: Double? = nil, in range: ClosedRange<Double>? = nil) throws -> Double {
        let value: Double
        if let number = raw[key]?.number ?? raw[key]?.string.flatMap(Double.init) { value = number }
        else if let fallback, raw[key] == nil || raw[key]!.isNull { value = fallback }
        else { throw EditError.invalid("\(key) is required (a number).") }
        guard value.isFinite else { throw EditError.invalid("\(key) must be a finite number.") }
        if let range, !range.contains(value) { throw EditError.invalid("\(key) must be between \(range.lowerBound.formatted()) and \(range.upperBound.formatted()).") }
        return value
    }
    func bool(_ key: String, default fallback: Bool) -> Bool { raw[key]?.bool ?? fallback }
    /// A 1-based position, returned 0-based.
    func position(_ key: String, count: Int) throws -> Int? {
        guard raw[key] != nil, !(raw[key]!.isNull) else { return nil }
        let value = try number(key)
        guard value.rounded() == value, Int(value) >= 1, Int(value) <= max(1, count) else { throw EditError.invalid("\(key) must be between 1 and \(max(1, count)).") }
        return Int(value) - 1
    }
}
