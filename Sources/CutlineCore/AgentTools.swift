@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public typealias AgentProgress = @Sendable (Double, String) -> Void

public struct AgentToolResult: Sendable {
    public var text: String
    /// JPEG frames the agent can look at.
    public var images: [Data]
    public var isError: Bool
    public init(text: String, images: [Data] = [], isError: Bool = false) { self.text = text; self.images = images; self.isError = isError }
    public init(_ value: JSON) { self.init(text: value.prettyText) }
    public var json: JSON {
        let content: [JSON] = [["type": "text", "text": .string(text)]] + images.map { ["type": "image", "data": .string($0.base64EncodedString()), "mimeType": "image/jpeg"] }
        return ["content": .array(content), "isError": .bool(isError)]
    }
}

/// The tools Cutline offers agents. Everything works on files: recordings, `.cutline` projects
/// and exported MP4s. The app reloads an open project when a tool changes it.
public final class AgentTools: @unchecked Sendable {
    public let support: URL
    public let exportRoot: URL
    public let appVersion: String
    /// Long jobs answer with a job id after this long, inside agents' tool timeouts (Codex's default is 60 s).
    public let handoffSeconds: Double
    let openInApp: @Sendable (URL) throws -> Void
    let jobs = AgentJobs()
    let files = FileQueue()

    public init(support: URL = LocalTools.support, exportRoot: URL = AgentTools.defaultExportRoot, appVersion: String = AgentTools.bundleVersion,
                handoffSeconds: Double = 40, openInApp: @escaping @Sendable (URL) throws -> Void = { try AgentTools.openWithCutline($0) }) {
        self.support = support; self.exportRoot = exportRoot; self.appVersion = appVersion; self.handoffSeconds = handoffSeconds; self.openInApp = openInApp
    }

    public static var defaultExportRoot: URL {
        if let root = LocalTools.testingRoot { return root }
        let defaults: UserDefaults = AppEnvironment.hostBundle == Bundle.main ? .standard : AppEnvironment.hostBundle.bundleIdentifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if let saved = defaults.string(forKey: "export-folder") { return URL(fileURLWithPath: saved, isDirectory: true) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline", isDirectory: true)
    }
    public static var bundleVersion: String { AppEnvironment.hostBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
    /// Shows a project in the Cutline app this connector came with.
    public static func openWithCutline(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let app = AppEnvironment.hostBundle.bundleURL
        process.arguments = app.pathExtension == "app" ? ["-a", app.path, url.path] : [url.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EditError.invalid("Couldn’t open Cutline. Open \(url.lastPathComponent) from Cutline’s File menu instead.") }
    }

    // MARK: - Catalog

    struct Spec {
        let name: String, title: String, description: String
        let properties: [String: JSON], required: [String]
        var readOnly = false, destructive = false, idempotent = false
    }
    static let specs: [Spec] = [
        Spec(name: "get_setup", title: "Check Cutline setup",
             description: "Start here. Lists saved facecam layouts, the channel badge on shorts (Kick/Twitch usernames, which logo, placement), whether captions and MKV conversion are available, and the default output folder.",
             properties: [:], required: [], readOnly: true, idempotent: true),
        Spec(name: "inspect_video", title: "Inspect a video",
             description: "Length, size, frame rate and audio tracks of a video file. OBS MKV/FLV/TS recordings are copied to an MP4 beside the original (no quality loss) and that path is returned; use it from then on.",
             properties: ["path": string("Video file path.")], required: ["path"], idempotent: true),
        Spec(name: "view_frame", title: "Look at a frame",
             description: "Returns images so you can see the video. With video_path: frames of the recording at source seconds (use this to measure facecam and gameplay boxes). With project_path: the finished render at timeline seconds, including the short layout, hook, captions and branding.",
             properties: ["video_path": string("A recording to look at."), "project_path": string("A .cutline project to preview as rendered."),
                          "time": number("Seconds. Defaults to 0."), "times": ["type": "array", "items": ["type": "number"], "description": "Up to 6 times, for a quick contact sheet."],
                          "size": number("Longest side in pixels, 160–1920. Default 768.")], required: [], readOnly: true, idempotent: true),
        Spec(name: "find_moments", title: "Find moments in a stream",
             description: "Scans a recording for highlights (loud reactions and busy gameplay) and returns moments with start/end seconds, a score and hook ideas. Results are measurements, not judgments: look at them with view_frame and pick the good ones. Rescans of the same file are instant.",
             properties: ["video_path": string("The stream recording."),
                          "layout": string("A saved layout name from get_setup. Sets the mic track and the gameplay area to watch."),
                          "sensitivity": number("0 = fewer, stronger moments; 1 = more, looser. Default 0.5."), "max_moments": number("1–100. Default 20."),
                          "audio_track": number("Audio track to listen to for reactions (1 = first). Usually the mic.")], required: ["video_path"], idempotent: true),
        Spec(name: "export_shorts", title: "Export shorts from a stream",
             description: "Turns moments of one recording into finished vertical shorts (9:16: facecam on top, gameplay below, hook text for the first 3 seconds, channel badge). Saves MP4s plus editable .cutline projects in a new folder. Needs a layout (saved layout name, or facecam and gameplay boxes) and the channel badge username from get_setup.",
             properties: ["video_path": string("The stream recording."),
                          "moments": ["type": "array", "description": "1–100 moments.", "items": ["type": "object", "properties": ["start": ["type": "number"], "end": ["type": "number"], "hook": ["type": "string", "description": "1–80 characters, one line."]], "required": ["start", "end", "hook"]]],
                          "layout": string("Saved layout name from get_setup."), "facecam": region("Facecam area of the recording."), "gameplay": region("Gameplay area of the recording."),
                          "audio_tracks": ["type": "array", "items": ["type": "number"], "description": "Tracks heard in the shorts (1 = first). Default: from the layout, else track 1."],
                          "captions": bool("Transcribe speech into captions (needs Whisper; see get_setup)."), "quality": ["type": "number", "enum": [720, 1080, 2160], "description": "Default 1080."],
                          "output_folder": string("Parent folder. Default: the folder from get_setup.")], required: ["video_path", "moments"]),
        Spec(name: "create_project", title: "Create an editing project",
             description: "Creates a .cutline project for any edit (a short, a montage, a YouTube video). Returns the project with numbered videos and clips. Then change it with edit_project.",
             properties: ["path": string("Where to save, ending in .cutline."), "videos": ["type": "array", "items": ["type": "string"], "description": "Video files to add."],
                          "format": ["type": "string", "enum": ["short", "youtube"], "description": "short = vertical 9:16 with facecam layout (default); youtube = 16:9."],
                          "name": string("Project name."), "layout": string("Saved layout name to apply to every video."),
                          "add_whole_videos": bool("Put each video on the timeline in full. Default false."), "overwrite": bool("Replace an existing file. Ask the user first.")],
             required: ["path"]),
        Spec(name: "read_project", title: "Read a project",
             description: "The project's videos, timeline clips (with numbers and timeline positions), hooks, captions and anything blocking export.",
             properties: ["path": string("A .cutline project.")], required: ["path"], readOnly: true, idempotent: true),
        Spec(name: "edit_project", title: "Edit a project",
             description: """
             Applies changes in order, all or nothing, and saves. If the project is open in Cutline it updates live and the user can undo.
             Clips are numbered 1… in timeline order after each previous change; videos by number, id or path (a new path is added). Source times are seconds in the video; timeline times are seconds in the edit.
             Each operation is {"op": name, …}:
             add_video {path} · add_clip {video, start?, end?, position?, volume?} · remove_clip {clip} · trim_clip {clip, start?, end?} (source seconds) · move_clip {clip, position}
             split {time} · keep_range {start, end} · cut_range {start, end} (timeline seconds) · set_volume {clip, volume 0–2} · set_track_volume {clip, track, volume} · set_speed {clip, speed 0.25–4}
             set_format {format: short|youtube} · set_hook {text} (every clip) · set_clip_hook {clip, text} · set_layout {video?, layout} or {video?, facecam {x,y,width,height}, gameplay {…}, fit_gameplay?} (fractions of the source frame from its top-left)
             add_captions {captions: [{start, end, text}]} (timeline seconds) · set_caption_text {caption, text} · clear_captions · set_caption_style {font_size?, position? 0.02–0.9 from bottom, uppercase?, color? hex, background?} · set_captions_burned {on}
             add_music {path, start?, volume? (default 0.3), fade_in?, fade_out?} · set_quality {resolution? 720|1080|2160, fps?} · rename {name}
             """,
             properties: ["path": string("A .cutline project."), "operations": ["type": "array", "items": ["type": "object", "properties": ["op": ["type": "string", "enum": .array(AgentEditor.operations.map(JSON.string))]], "required": ["op"]]]],
             required: ["path", "operations"]),
        Spec(name: "transcribe", title: "Caption a project",
             description: "Writes captions from the speech in each clip, on this Mac with Whisper (get_setup says if it is ready). Replaces earlier captions for those videos. Without Whisper, add captions yourself with edit_project add_captions.",
             properties: ["path": string("A .cutline project."), "audio_track": number("Track with the voice (1 = first). Default: the mic from the layout, else track 1."),
                          "language": string("Language code such as en, or auto (default).")], required: ["path"]),
        Spec(name: "export_video", title: "Export a project",
             description: "Renders a project to an MP4. Never overwrites the source videos. Default output: the project name in the folder from get_setup.",
             properties: ["path": string("A .cutline project."), "output_path": string("Where to save the .mp4."), "overwrite": bool("Replace an existing file. Ask the user first.")],
             required: ["path"]),
        Spec(name: "open_in_cutline", title: "Show in Cutline",
             description: "Opens a .cutline project in the Cutline app so the user can watch, tweak and export it. While it is open, edit_project changes appear there live.",
             properties: ["path": string("A .cutline project.")], required: ["path"], idempotent: true),
        Spec(name: "set_branding", title: "Set the channel badge",
             description: "Sets the creator's Kick and Twitch usernames and the badge drawn on every short: a Kick or Twitch logo container with @username. Place it with x and y (its centre as fractions of the 9:16 frame from the top-left; default centred on the strip between facecam and gameplay, x 0.5, y 0.31) and size (1 = standard, 0.5–2.5). These are the user's settings: only change them when they ask or agree. Check placement with view_frame on a short project.",
             properties: ["kick": string("Kick username (a channel address is fine)."), "twitch": string("Twitch username."),
                          "badge": ["type": "string", "enum": ["kick", "twitch"], "description": "Which logo container shorts show."],
                          "x": number("Badge centre across the frame, 0–1."), "y": number("Badge centre down the frame, 0–1."), "size": number("0.5–2.5; 1 is standard.")],
             required: [], destructive: true, idempotent: true),
        Spec(name: "wait_for_job", title: "Wait for a job",
             description: "Waits up to about 40 seconds for a long job (scan, export, captions) and returns its result, or its progress if it is still running.",
             properties: ["job_id": string("The id a tool returned.")], required: ["job_id"], readOnly: true),
        Spec(name: "cancel_job", title: "Cancel a job",
             description: "Stops a running job. Nothing half-finished is left behind.",
             properties: ["job_id": string("The id a tool returned.")], required: ["job_id"], idempotent: true)
    ]
    static func string(_ description: String) -> JSON { ["type": "string", "description": .string(description)] }
    static func number(_ description: String) -> JSON { ["type": "number", "description": .string(description)] }
    static func bool(_ description: String) -> JSON { ["type": "boolean", "description": .string(description)] }
    static func region(_ description: String) -> JSON {
        ["type": "object", "description": .string(description + " Fractions of the source frame from its top-left: {x, y, width, height}, each 0–1."),
         "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]], "required": ["x", "y", "width", "height"]]
    }

    public var definitions: [JSON] {
        Self.specs.map { spec in
            ["name": .string(spec.name), "title": .string(spec.title), "description": .string(spec.description),
             "inputSchema": ["type": "object", "properties": .object(spec.properties), "required": .array(spec.required.map(JSON.string))],
             "annotations": ["title": .string(spec.title), "readOnlyHint": .bool(spec.readOnly), "destructiveHint": .bool(spec.destructive),
                             "idempotentHint": .bool(spec.idempotent), "openWorldHint": false]]
        }
    }
    public func has(_ name: String) -> Bool { Self.specs.contains { $0.name == name } }

    public func call(_ name: String, arguments: JSON, progress: @escaping AgentProgress = { _, _ in }) async throws -> AgentToolResult {
        let a = Arguments(arguments)
        switch name {
        case "get_setup": return AgentToolResult(setup())
        case "inspect_video": return try await job(name, progress) { try await self.inspectVideo(a, $0) }
        case "view_frame": return try await viewFrame(a)
        case "find_moments": return try await job(name, progress) { try await self.findMoments(a, $0) }
        case "export_shorts": return try await job(name, progress) { try await self.exportShorts(a, $0) }
        case "create_project": return try await job(name, progress) { try await self.createProject(a, $0) }
        case "read_project":
            let url = try projectURL(a)
            return AgentToolResult(summary(try EditProject.read(from: url), at: url))
        case "edit_project": return try await job(name, progress) { try await self.editProject(a, $0) }
        case "transcribe": return try await job(name, progress) { try await self.transcribe(a, $0) }
        case "export_video": return try await job(name, progress) { try await self.exportVideo(a, $0) }
        case "open_in_cutline":
            let url = try projectURL(a)
            _ = try EditProject.read(from: url)
            try openInApp(url)
            return AgentToolResult(text: "Opened \(url.lastPathComponent) in Cutline. Changes made with edit_project now appear there as they happen.")
        case "set_branding":
            var branding = self.branding()
            if let name = try a.optionalString("kick") { branding.kick = ShortBranding.username(name) }
            if let name = try a.optionalString("twitch") { branding.twitch = ShortBranding.username(name) }
            if let value = try a.optionalString("badge") {
                guard let platform = ShortBranding.Platform(rawValue: value.lowercased()) else { throw EditError.invalid("badge is kick or twitch.") }
                branding.badge = platform
            }
            if a.raw["x"] != nil { branding.placement.x = try a.number("x", in: 0...1) }
            if a.raw["y"] != nil { branding.placement.y = try a.number("y", in: 0...1) }
            if a.raw["size"] != nil { branding.placement.size = try a.number("size", in: BadgePlacement.sizes) }
            try branding.validate()
            try CreatorProfileStore.save(branding, to: support)
            return AgentToolResult(Self.json(branding))
        case "wait_for_job":
            guard let job = jobs.job(try a.string("job_id")) else { throw EditError.invalid("There’s no job with that id. Jobs are kept until Cutline’s connector restarts.") }
            return try await jobs.wait(job, seconds: handoffSeconds, progress: progress)
        case "cancel_job":
            guard let job = jobs.job(try a.string("job_id")) else { throw EditError.invalid("There’s no job with that id.") }
            job.task?.cancel()
            return AgentToolResult(text: job.result == nil ? "Cancelled \(job.tool) (\(job.id))." : "\(job.id) had already finished.")
        default: throw EditError.invalid("Unknown tool \(name).")
        }
    }
    private func job(_ name: String, _ progress: @escaping AgentProgress, _ work: @escaping @Sendable (@escaping AgentProgress) async throws -> AgentToolResult) async throws -> AgentToolResult {
        try await jobs.wait(jobs.start(name, work), seconds: handoffSeconds, progress: progress)
    }

    // MARK: - Setup and media

    func presets() -> [ScenePreset] { (try? ScenePresetStore.load(from: support)) ?? [] }
    func branding() -> ShortBranding { (try? CreatorProfileStore.load(from: support)) ?? ShortBranding() }

    func setup() -> JSON {
        let profile = branding()
        let whisper = LocalTools.executable("whisper-cli") != nil && LocalTools.executable("ffmpeg") != nil
        let model = WhisperModel.allCases.first { $0.installed }
        return [
            "app": .string("Cutline \(appVersion)"),
            "branding": Self.json(profile),
            "saved_layouts": .array(presets().map { preset in
                ["name": .string(preset.name), "facecam": Self.json(preset.framing.camera), "gameplay": Self.json(preset.framing.gameplay),
                 "audio_tracks": .array(preset.audioRoles.enumerated().map { ["track": JSON($0.offset + 1), "role": .string($0.element.label)] })]
            }),
            "captions": .string(whisper && model != nil ? "Ready (Whisper \(model!.rawValue))." : "Not set up: open Cutline and turn on captions, or install whisper-cli and FFmpeg. You can still add captions with edit_project add_captions."),
            "mkv_conversion": .string(LocalTools.executable("ffmpeg") != nil ? "Ready." : "Needs FFmpeg. Otherwise remux to MP4 in OBS (File → Remux Recordings)."),
            "output_folder": .string(exportRoot.path),
            "notes": .array(profile.displayText.isEmpty ? [.string("Shorts need the user\u{2019}s \(profile.badge.label) username for the channel badge. Ask them, then call set_branding.")] : [])
        ]
    }

    /// A playable video: OBS containers become an MP4 beside the original.
    func prepareVideo(_ path: String, _ progress: AgentProgress) async throws -> (url: URL, convertedFrom: URL?) {
        let url = AgentPaths.url(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditError.invalid("There’s no file at \(url.path).") }
        guard MediaConversion.needsConversion(url) else { return (url, nil) }
        progress(0, "Copying \(url.lastPathComponent) into an MP4 (no quality loss)…")
        return (try await MediaConversion.convertToMP4(url), url)
    }
    func media(_ path: String, _ progress: AgentProgress) async throws -> MediaItem {
        try await CompositionEngine.inspect(prepareVideo(path, progress).url)
    }

    func inspectVideo(_ a: Arguments, _ progress: AgentProgress) async throws -> AgentToolResult {
        let prepared = try await prepareVideo(try a.string("path"), progress)
        let item = try await CompositionEngine.inspect(prepared.url)
        let names = await AudioTrackNames.load(prepared.url)
        let roles = AudioRole.guess(count: item.audioTrackCount ?? 0, names: names)
        var info: [String: JSON] = ["path": .string(prepared.url.path), "length": Self.round(item.duration), "length_text": .string(clockTime(item.duration)),
                                    "audio_tracks": .array(roles.indices.map { ["track": JSON($0 + 1), "name": JSON(names[safe: $0] ?? nil), "likely": .string(roles[$0].label)] })]
        if let video = await Self.videoInfo(prepared.url) { info["width"] = JSON(Int(video.size.width)); info["height"] = JSON(Int(video.size.height)); info["fps"] = Self.round(video.fps) }
        if let original = prepared.convertedFrom { info["converted_from"] = .string(original.path) }
        return AgentToolResult(.object(info))
    }

    static func videoInfo(_ url: URL) async -> (size: CGSize, fps: Double)? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) else { return nil }
        let rect = CGRect(origin: .zero, size: loaded.0).applying(loaded.1)
        return (CGSize(width: abs(rect.width), height: abs(rect.height)), Double(loaded.2))
    }

    func viewFrame(_ a: Arguments) async throws -> AgentToolResult {
        var times = (a.raw["times"]?.array ?? []).compactMap(\.number)
        if times.isEmpty { times = [try a.number("time", default: 0)] }
        guard times.count <= 6, times.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw EditError.invalid("Give up to 6 times, each 0 or more seconds.") }
        let side = try a.number("size", default: 768, in: 160...1920)
        let generator: AVAssetImageGenerator, length: Double, label: String
        var notes: [String] = []
        if let path = try a.optionalString("project_path") {
            let url = AgentPaths.url(path)
            let project = try EditProject.read(from: url)
            let render = try await CompositionEngine.build(project, branding: branding())
            generator = AVAssetImageGenerator(asset: render.asset); generator.videoComposition = render.video
            length = project.duration; label = project.name
            if project.workflow == .mobileShort && project.media.contains(where: { $0.shortFraming?.confirmed != true }) { notes.append("The facecam/gameplay layout hasn’t been set yet, so this uses a default. Use edit_project set_layout.") }
        } else if let path = try a.optionalString("video_path") {
            let url = try await prepareVideo(path, { _, _ in }).url
            let asset = AVURLAsset(url: url)
            generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            length = try await asset.load(.duration).seconds; label = url.lastPathComponent
        } else { throw EditError.invalid("Give video_path or project_path.") }
        generator.maximumSize = CGSize(width: side, height: side)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance; generator.requestedTimeToleranceAfter = tolerance
        var images: [Data] = [], lines: [String] = []
        for time in times {
            let clamped = max(0, min(time, max(0, length - 0.05)))
            let frame = try await generator.image(at: CMTime(seconds: clamped, preferredTimescale: 600)).image
            images.append(try Self.jpeg(frame))
            lines.append("\(clockTime(clamped)) (\(Self.decimal(clamped)) s): \(frame.width)×\(frame.height)")
        }
        return AgentToolResult(text: (["\(label), \(clockTime(length)) long."] + lines + notes).joined(separator: "\n"), images: images)
    }
    static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw EditError.invalid("Couldn’t encode the frame.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditError.invalid("Couldn’t encode the frame.") }
        return data as Data
    }

    // MARK: - Stream clipping

    func scanSettings() -> AutoClipSettings {
        let url = support.appendingPathComponent("autoclip-profiles.json")
        let profiles = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: AutoClipSettings].self, from: $0) } ?? [:]
        return profiles["last"] ?? AutoClipSettings()
    }
    func preset(named name: String) throws -> ScenePreset {
        let all = presets()
        guard let preset = all.first(where: { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }) else {
            throw EditError.invalid(all.isEmpty ? "There are no saved layouts. Give facecam and gameplay boxes instead (view_frame helps you measure them)." : "No saved layout is called “\(name)”. Saved layouts: \(all.map(\.name).joined(separator: ", ")).")
        }
        return preset
    }

    func findMoments(_ a: Arguments, _ progress: @escaping AgentProgress) async throws -> AgentToolResult {
        var item = try await media(try a.string("video_path"), progress)
        var settings = scanSettings()
        let tracks = item.audioTrackCount ?? 0
        if let name = try a.optionalString("layout") {
            let preset = try preset(named: name)
            preset.apply(to: &item)
            settings.motionRegion = preset.motionRegion
            let routes = AudioRoutes(item.audioRoles ?? [])
            settings.audioTrack = routes.detect; settings.outputAudioTracks = routes.export
        }
        if a.raw["audio_track"] != nil {
            let track = Int(try a.number("audio_track", in: 1...64))
            guard track <= tracks else { throw EditError.invalid("This recording has \(tracks) audio track\(tracks == 1 ? "" : "s").") }
            settings.audioTrack = track - 1
        }
        if tracks == 0 { settings.audioEnabled = false; settings.requireBoth = false }
        if settings.audioTrack >= tracks { settings.audioTrack = 0 }
        let export = settings.exportTracks.filter { $0 < max(1, tracks) }
        settings.outputAudioTracks = export.isEmpty ? [0] : export
        if a.raw["sensitivity"] != nil { settings.sensitivity = try a.number("sensitivity", in: 0...1) }
        if a.raw["max_moments"] != nil { settings.maxClips = Int(try a.number("max_moments", in: 1...100)) }
        try settings.validate()
        var analysis = ClipAnalysisCache.load(for: item, root: support)
        if analysis?.covers(settings) != true {
            analysis = try await ClipAnalyzer.analyze(media: item, settings: settings, existing: analysis, progress: { progress($0.fraction, $0.message) })
            try? ClipAnalysisCache.save(analysis!, root: support)
        }
        let report = try analysis!.report(settings: settings)
        let moments: [JSON] = report.candidates.enumerated().map { index, candidate in
            ["number": JSON(index + 1), "start": Self.round(candidate.start), "end": Self.round(candidate.end), "length": Self.round(candidate.end - candidate.start),
             "starts_at": .string(clockTime(candidate.start)), "title": .string(candidate.title), "score": Self.round(candidate.score),
             "why": .array(Array(Set(candidate.evidence.map(\.detail))).sorted().prefix(4).map(JSON.string)),
             "hook_ideas": .array(HookIdeas.suggestions(for: candidate).map(JSON.string))]
        }
        return AgentToolResult([
            "video_path": .string(item.url.path), "length": Self.round(item.duration),
            "listened_to_track": tracks == 0 ? .null : JSON(settings.audioTrack + 1),
            "moments": .array(moments),
            "next": .string(moments.isEmpty ? "Nothing stood out. Try sensitivity 0.8, another audio_track, or pick times yourself with view_frame." : "Check moments with view_frame, then export_shorts with a hook for each one you keep."),
            "warnings": .array(report.warnings.map(JSON.string))
        ])
    }

    func exportShorts(_ a: Arguments, _ progress: @escaping AgentProgress) async throws -> AgentToolResult {
        var item = try await media(try a.string("video_path"), progress)
        let tracks = item.audioTrackCount ?? 0
        if let name = try a.optionalString("layout") { try preset(named: name).apply(to: &item) }
        if a.raw["facecam"] != nil || a.raw["gameplay"] != nil {
            var operation: [String: JSON] = ["op": "set_layout", "video": 1]
            operation["facecam"] = a.raw["facecam"]; operation["gameplay"] = a.raw["gameplay"]
            var scratch = EditProject(); scratch.media = [item]
            try AgentEditor().apply([.object(operation)], to: &scratch)
            item = scratch.media[0]
        }
        guard item.shortFraming?.confirmed == true else {
            let names = presets().map(\.name)
            throw EditError.invalid("Say where the facecam and gameplay are: layout (\(names.isEmpty ? "none saved yet" : names.joined(separator: ", "))) or facecam and gameplay boxes. view_frame shows the recording so you can measure them.")
        }
        var export: [Int]
        if let list = a.raw["audio_tracks"]?.array {
            export = try list.map { value in
                guard let track = value.number, track.rounded() == track, Int(track) >= 1, Int(track) <= max(1, tracks) else { throw EditError.invalid("audio_tracks are numbers from 1 to \(max(1, tracks)).") }
                return Int(track) - 1
            }
        } else { export = item.audioRoles.map { AudioRoutes($0).export } ?? [0] }
        export = export.filter { $0 < max(1, tracks) }
        var settings = AutoClipSettings(); settings.outputAudioTracks = export.isEmpty ? [0] : export
        let report = AutoClipReport(media: item, settings: settings, candidates: [], evidence: [])
        guard let moments = a.raw["moments"]?.array, (1...100).contains(moments.count) else { throw EditError.invalid("Give 1–100 moments as {start, end, hook}.") }
        var candidates: [AutoClipCandidate] = [], hooks: [String: String] = [:]
        for (index, moment) in moments.enumerated() {
            let m = Arguments(moment), id = "moment-\(index + 1)"
            let start = try m.number("start"), end = try m.number("end")
            guard start >= 0, end <= item.duration + 0.01, end - start >= ClipReview.minimumLength, end - start <= ClipReview.maximumLength else {
                throw EditError.invalid("Moment \(index + 1) must be 1–180 seconds long inside the recording (0–\(Self.decimal(item.duration)) s).")
            }
            let hook = try m.string("hook").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hook.isEmpty, hook.count <= 80, !hook.contains(where: \.isNewline) else { throw EditError.invalid("Moment \(index + 1) needs a hook of 1–80 characters on one line.") }
            candidates.append(AutoClipCandidate(id: id, start: start, end: min(end, item.duration), score: 0, evidence: []))
            hooks[id] = hook
        }
        let profile = branding()
        do { try profile.validate() } catch { throw EditError.invalid("Shorts show a channel badge with the user’s \(profile.badge.label) username, which isn’t set. Ask them for it, then call set_branding.") }
        var options = ProjectSettings()
        if a.raw["quality"] != nil {
            options.resolution = Int(try a.number("quality"))
            guard [720, 1080, 2160].contains(options.resolution) else { throw EditError.invalid("quality is 720, 1080 or 2160.") }
        }
        var captions: [String: [TranscriptSegment]] = [:]
        if a.bool("captions", default: false) {
            let model = try whisperModel()
            let track = item.audioRoles.map { AudioRoutes($0).speech } ?? 0
            let count = candidates.count
            for (index, candidate) in candidates.enumerated() {
                let transcript = try await LocalTranscription.transcribe(media: item, audioTrack: min(track, max(0, tracks - 1)), model: model, range: ClipRange(start: candidate.start, end: candidate.end)) { value in
                    progress((Double(index) + value.fraction) / Double(count) * 0.4, "Writing captions for short \(index + 1) of \(count)…")
                }
                captions[candidate.id] = transcript.segments
            }
        }
        let parent = try a.optionalString("output_folder").map { AgentPaths.url($0, directory: true) } ?? exportRoot
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let offset = captions.isEmpty ? 0.0 : 0.4
        let folder = try await AutoClipBatch.export(report: report, candidates: candidates, to: parent, name: "\(item.name) shorts", options: options, hooks: hooks, branding: profile, captions: captions) {
            progress(offset + $0.fraction * (1 - offset), $0.message)
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return AgentToolResult([
            "folder": .string(folder.path), "shorts": .array(files.map { .string($0.path) }),
            "editable_projects": .string(folder.appendingPathComponent(AutoClipBatch.projectsFolder).path),
            "next": "Each short has an editable .cutline project: change one with edit_project and export_video, or open_in_cutline."
        ])
    }

    // MARK: - Projects

    func projectURL(_ a: Arguments, key: String = "path") throws -> URL {
        let url = AgentPaths.url(try a.string(key))
        guard url.pathExtension.lowercased() == "cutline" else { throw EditError.invalid("\(key) must be a .cutline project.") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditError.invalid("There’s no project at \(url.path). create_project makes one.") }
        return url
    }

    func createProject(_ a: Arguments, _ progress: @escaping AgentProgress) async throws -> AgentToolResult {
        var url = AgentPaths.url(try a.string("path"))
        if url.pathExtension.lowercased() != "cutline" { url = url.appendingPathExtension("cutline") }
        guard a.bool("overwrite", default: false) || !FileManager.default.fileExists(atPath: url.path) else {
            throw EditError.invalid("\(url.path) already exists. Use read_project and edit_project to change it, or ask the user before passing overwrite: true.")
        }
        let format = try a.optionalString("format") ?? "short"
        guard ["short", "youtube"].contains(format) else { throw EditError.invalid("format is short or youtube.") }
        var project = EditProject(workflow: format == "youtube" ? .youtubeVideo : .mobileShort)
        project.name = try a.optionalString("name").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let layout = try a.optionalString("layout").map { try preset(named: $0) }
        for path in (a.raw["videos"]?.array ?? []).compactMap(\.string) {
            var item = try await media(path, progress)
            guard !project.media.contains(where: { $0.url == item.url }) else { continue }
            layout?.apply(to: &item)
            project.media.append(item)
            if a.bool("add_whole_videos", default: false) {
                try AgentEditor(videos: [path: item]).apply([["op": "add_clip", "video": .string(item.id.uuidString)]], to: &project)
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try project.write(to: url)
        return AgentToolResult(summary(project, at: url))
    }

    func editProject(_ a: Arguments, _ progress: @escaping AgentProgress) async throws -> AgentToolResult {
        let url = try projectURL(a)
        guard let operations = a.raw["operations"]?.array else { throw EditError.invalid("operations is a list of changes such as {\"op\": \"trim_clip\", \"clip\": 1, \"end\": 30}.") }
        let paths = AgentEditor.referencedPaths(operations)
        var editor = AgentEditor(presets: presets())
        for path in Set(paths.videos) { editor.videos[path] = try await media(path, progress) }
        for path in Set(paths.music) {
            let asset = AVURLAsset(url: AgentPaths.url(path))
            guard FileManager.default.fileExists(atPath: AgentPaths.url(path).path), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw EditError.invalid("\(path) isn’t a readable audio file.") }
            editor.music[path] = try await asset.load(.duration).seconds
        }
        let ready = editor
        // Simultaneous edits to one project apply one after another instead of overwriting each other.
        return try await files.serialize(url) {
            var project = try EditProject.read(from: url)
            let notes = try ready.apply(operations, to: &project)
            try project.write(to: url)
            var result = self.summary(project, at: url).object ?? [:]
            result["changes"] = .array(notes.map(JSON.string))
            return AgentToolResult(.object(result))
        }
    }

    func whisperModel() throws -> WhisperModel {
        guard LocalTools.executable("whisper-cli") != nil, LocalTools.executable("ffmpeg") != nil, let model = WhisperModel.allCases.first(where: \.installed) else {
            throw EditError.invalid("Captions from speech need Whisper on this Mac, which isn’t set up (see get_setup). You can add captions yourself with edit_project add_captions.")
        }
        return model
    }

    func transcribe(_ a: Arguments, _ progress: @escaping AgentProgress) async throws -> AgentToolResult {
        let url = try projectURL(a)
        let model = try whisperModel()
        let language = try a.optionalString("language") ?? "auto"
        let original = try EditProject.read(from: url)
        let used = original.media.filter { item in original.clips.contains { $0.mediaID == item.id } }
        guard !used.isEmpty else { throw EditError.invalid("Add clips to the timeline before captioning.") }
        var transcripts: [SourceTranscript] = []
        for (index, item) in used.enumerated() {
            let tracks = max(1, item.audioTrackCount ?? 1)
            let track = a.raw["audio_track"] != nil ? Int(try a.number("audio_track", in: 1...Double(tracks))) - 1 : min(item.audioRoles.map { AudioRoutes($0).speech } ?? 0, tracks - 1)
            let ranges = TimelineRange.merged(original.clips.filter { $0.mediaID == item.id }.map { TimelineRange(start: $0.sourceIn, end: $0.sourceOut) }, duration: item.duration)
            var segments: [TranscriptSegment] = []
            for range in ranges {
                let part = try await LocalTranscription.transcribe(media: item, audioTrack: track, model: model, language: language, range: ClipRange(start: range.start, end: range.end)) { value in
                    progress((Double(index) + value.fraction) / Double(used.count), "Listening to \(item.name)…")
                }
                segments += part.segments
            }
            transcripts.append(SourceTranscript(mediaID: item.id, audioTrack: track, language: language, segments: segments))
        }
        let finished = transcripts
        return try await files.serialize(url) {
            // Re-read so edits made while this ran are kept.
            var project = try EditProject.read(from: url)
            for transcript in finished where project.media.contains(where: { $0.id == transcript.mediaID }) {
                project.transcripts = (project.transcripts ?? []).filter { $0.mediaID != transcript.mediaID } + [transcript]
                project.generateCaptions(from: transcript)
            }
            try project.write(to: url)
            var result = self.summary(project, at: url).object ?? [:]
            result["changes"] = .array([.string("Wrote \(project.projectedCaptions().count) captions. Fix words with set_caption_text.")])
            return AgentToolResult(.object(result))
        }
    }

    func exportVideo(_ a: Arguments, _ progress: @escaping AgentProgress) async throws -> AgentToolResult {
        let url = try projectURL(a)
        let project = try EditProject.read(from: url)
        guard !project.clips.isEmpty else { throw EditError.invalid("The timeline is empty. Add clips with edit_project add_clip.") }
        try project.validateForExport()
        let profile = branding()
        if project.workflow == .mobileShort {
            do { try profile.validate() } catch { throw EditError.invalid("Shorts show a channel badge with the user’s \(profile.badge.label) username, which isn’t set. Ask them for it, then call set_branding.") }
        }
        var output: URL
        if let path = try a.optionalString("output_path") {
            output = AgentPaths.url(path)
            if output.pathExtension.lowercased() != "mp4" { output = output.appendingPathExtension("mp4") }
            guard a.bool("overwrite", default: false) || !FileManager.default.fileExists(atPath: output.path) else {
                throw EditError.invalid("\(output.path) already exists. Choose another output_path, or ask the user before passing overwrite: true.")
            }
        } else { output = Self.unique(exportRoot.appendingPathComponent(AutoClipBatch.fileName(project.name) + ".mp4")) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        progress(0, "Preparing \(project.name)…")
        let render = try await CompositionEngine.build(project, branding: profile)
        let sources = project.media.map(\.url) + (project.music ?? []).map(\.url)
        try await ExportDestination.write(to: output, protecting: sources) { temporary in
            try await CompositionEngine.export(render, to: temporary) { progress($0, "Exporting \(project.name)…") }
        }
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return AgentToolResult(["output": .string(output.path), "length": Self.round(project.duration), "format": .string(project.outputFormat.label),
                                "size": .string(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))])
    }

    static func unique(_ url: URL) -> URL {
        var candidate = url, index = 2
        let stem = url.deletingPathExtension().lastPathComponent, folder = url.deletingLastPathComponent()
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = folder.appendingPathComponent("\(stem) \(index).\(url.pathExtension)"); index += 1 }
        return candidate
    }

    /// What an agent needs to plan the next edit, with everything numbered as edit_project expects.
    func summary(_ project: EditProject, at url: URL) -> JSON {
        var problems: [String] = []
        if project.clips.isEmpty { problems.append("The timeline is empty.") }
        do { try project.validateForExport() } catch { problems.append(error.localizedDescription) }
        if project.workflow == .mobileShort, branding().displayText.isEmpty { problems.append("Shorts need the user’s username for the channel badge: ask them, then call set_branding.") }
        var cursor = 0.0
        let clips: [JSON] = project.clips.enumerated().map { index, clip in
            defer { cursor += clip.duration }
            var value: [String: JSON] = ["number": JSON(index + 1), "id": .string(clip.id.uuidString), "video": JSON((project.media.firstIndex { $0.id == clip.mediaID } ?? -1) + 1),
                                         "source_start": Self.round(clip.sourceIn), "source_end": Self.round(clip.sourceOut), "timeline_start": Self.round(cursor), "length": Self.round(clip.duration)]
            if clip.volume != 1 { value["volume"] = Self.round(clip.volume) }
            if clip.speed != 1 { value["speed"] = Self.round(clip.speed) }
            if let hook = clip.shortHook { value["hook"] = .string(hook) }
            if let gains = clip.adjustments?.audioGains, !gains.isEmpty {
                value["track_volumes"] = .object(Dictionary(uniqueKeysWithValues: gains.compactMap { key, gain in Int(key).map { (String($0 + 1), Self.round(gain)) } }))
            }
            return .object(value)
        }
        let videos: [JSON] = project.media.enumerated().map { index, item in
            var value: [String: JSON] = ["number": JSON(index + 1), "id": .string(item.id.uuidString), "name": .string(item.name), "path": .string(item.url.path),
                                         "length": Self.round(item.duration), "audio_tracks": JSON(item.audioTrackCount ?? 0)]
            if project.workflow == .mobileShort {
                value["layout"] = item.shortFraming.map { framing in
                    ["set": .bool(framing.confirmed), "facecam": Self.json(framing.camera), "gameplay": Self.json(framing.gameplay)]
                } ?? ["set": false]
            }
            return .object(value)
        }
        let captions = project.projectedCaptions()
        var result: [String: JSON] = [
            "path": .string(url.path), "name": .string(project.name),
            "format": project.workflow.map { .string($0 == .mobileShort ? "short" : "youtube") } ?? .null,
            "length": Self.round(project.duration), "quality": .string("\(project.options.resolution)p, \(project.options.fps) fps"),
            "videos": .array(videos), "clips": .array(clips),
            "captions": .array(captions.prefix(300).map { ["id": .string($0.id.uuidString), "start": Self.round($0.start), "end": Self.round($0.end), "text": .string($0.text)] }),
            "export_ready": .bool(problems.isEmpty), "problems": .array(problems.map(JSON.string))
        ]
        if project.workflow == .mobileShort { result["hook"] = JSON(project.shortHook) }
        if captions.count > 300 { result["captions_note"] = .string("Showing the first 300 of \(captions.count) captions.") }
        if let music = project.music, !music.isEmpty { result["music"] = .array(music.map { ["path": .string($0.url.path), "start": Self.round($0.start), "volume": Self.round($0.volume)] }) }
        return .object(result)
    }

    static func json(_ branding: ShortBranding) -> JSON {
        ["kick": branding.kick.isEmpty ? .null : .string(branding.kick), "twitch": branding.twitch.isEmpty ? .null : .string(branding.twitch),
         "badge": .string(branding.badge.rawValue), "shows": branding.displayText.isEmpty ? .null : .string(branding.displayText),
         "placement": ["x": round(branding.placement.x), "y": round(branding.placement.y), "size": round(branding.placement.size)]]
    }
    static func round(_ value: Double) -> JSON { JSON((value * 100).rounded() / 100) }
    static func decimal(_ value: Double) -> String { String(format: "%.2f", value) }
    static func json(_ region: ClipScanRegion) -> JSON {
        func r(_ v: Double) -> JSON { JSON((v * 1000).rounded() / 1000) }
        return ["x": r(region.x), "y": r(region.y), "width": r(region.width), "height": r(region.height)]
    }
}

/// Runs work on one file in the order it was asked for.
actor FileQueue {
    private var tails: [String: Task<Void, Never>] = [:]
    func serialize<T: Sendable>(_ url: URL, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let key = url.standardizedFileURL.path, previous = tails[key]
        let task = Task { () async throws -> T in
            await previous?.value
            return try await work()
        }
        tails[key] = Task { _ = try? await task.value }
        return try await task.value
    }
}

/// Long work outlives a single tool call: after the hand-off time the agent gets a job id and
/// waits with wait_for_job, so no agent's tool timeout cuts an export short.
final class AgentJobs: @unchecked Sendable {
    final class Job: @unchecked Sendable {
        let id: String, tool: String
        private let lock = NSLock()
        private var state = (fraction: 0.0, message: "Starting…")
        private var outcome: Result<AgentToolResult, Error>?
        private var listener: AgentProgress?
        var task: Task<Void, Never>?
        init(id: String, tool: String) { self.id = id; self.tool = tool }
        var result: Result<AgentToolResult, Error>? { lock.lock(); defer { lock.unlock() }; return outcome }
        var progress: (fraction: Double, message: String) { lock.lock(); defer { lock.unlock() }; return state }
        func update(_ fraction: Double, _ message: String) {
            lock.lock(); state = (fraction, message); let listener = listener; lock.unlock()
            listener?(fraction, message)
        }
        func listen(_ value: AgentProgress?) { lock.lock(); listener = value; lock.unlock() }
        func finish(_ value: Result<AgentToolResult, Error>) { lock.lock(); outcome = value; lock.unlock() }
    }
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]

    func start(_ tool: String, _ work: @escaping @Sendable (@escaping AgentProgress) async throws -> AgentToolResult) -> Job {
        let job = Job(id: "job-" + UUID().uuidString.prefix(8).lowercased(), tool: tool)
        lock.lock()
        // Keep finished jobs for a while so a late wait_for_job still gets its answer.
        if jobs.count > 50 { for (id, old) in jobs where old.result != nil { jobs[id] = nil } }
        jobs[job.id] = job
        lock.unlock()
        job.task = Task {
            do { job.finish(.success(try await work { job.update($0, $1) })) } catch { job.finish(.failure(error)) }
        }
        return job
    }
    func job(_ id: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id.trimmingCharacters(in: .whitespaces)] }

    /// The job's result, or a progress report if it needs longer. Cancelling the waiting
    /// request before the hand-off cancels the job too.
    func wait(_ job: Job, seconds: Double, progress: @escaping AgentProgress) async throws -> AgentToolResult {
        job.listen(progress); defer { job.listen(nil) }
        let deadline = Date().addingTimeInterval(seconds)
        while job.result == nil && Date() < deadline {
            if Task.isCancelled { job.task?.cancel(); throw CancellationError() }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let result = job.result { return try result.get() }
        let state = job.progress
        return AgentToolResult([
            "status": "running", "job_id": .string(job.id), "progress": .string("\(Int(state.fraction * 100))%"), "message": .string(state.message),
            "next": .string("Still working. Call wait_for_job with job_id \(job.id) to keep waiting.")
        ])
    }
}
