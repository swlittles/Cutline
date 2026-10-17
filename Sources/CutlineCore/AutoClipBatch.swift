import Foundation

public enum AutoClipBatch {
    public static let projectsFolder = "Editable projects"
    /// Each successful batch is a new directory: the MP4s at the top, editable projects and the
    /// scan report in a subfolder. Failures and cancellation leave no half-published batch.
    public static func export(report: AutoClipReport, candidates: [AutoClipCandidate], to parent: URL, name: String? = nil, options: ProjectSettings = ProjectSettings(), hooks: [String: String] = [:], branding: ShortBranding = ShortBranding(), captions: [String: [TranscriptSegment]] = [:], progress: @escaping @Sendable (ClipScanProgress) -> Void = { _ in }) async throws -> URL {
        guard parent.isFileURL, !candidates.isEmpty, candidates.count <= 100 else { throw EditError.invalid("Select clips and a local output folder.") }
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".cutline-clips-\(token)", isDirectory: true)
        let destination = uniqueFolder(in: parent, named: name.map(fileName) ?? "Cutline clips \(token.prefix(8))")
        let projects = staging.appendingPathComponent(projectsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var exported = report; exported.candidates = candidates
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            let project = try clipProject(candidate, report: report, options: options, hook: hooks[candidate.id], captions: captions[candidate.id])
            try project.validateForExport()
            try branding.validate()
            let stem = String(format: "%02d", index + 1) + " - " + fileName(hooks[candidate.id].flatMap { $0.isEmpty ? nil : $0 } ?? candidate.title)
            let render = try await CompositionEngine.build(project, branding: branding)
            try await CompositionEngine.export(render, to: staging.appendingPathComponent(stem + ".mp4")) { value in
                progress(ClipScanProgress((Double(index) + value) / Double(candidates.count), "Exporting short \(index + 1) of \(candidates.count)…"))
            }
            try project.write(to: projects.appendingPathComponent(stem + ".cutline"))
        }
        try encoder.encode(exported).write(to: projects.appendingPathComponent("analysis.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
        progress(ClipScanProgress(1, "Exported \(candidates.count) \(candidates.count == 1 ? "clip" : "clips")."))
        return destination
    }
    /// The same editable project is previewed, exported and saved beside each MP4.
    public static func clipProject(_ candidate: AutoClipCandidate, report: AutoClipReport, options: ProjectSettings, hook: String?, captions: [TranscriptSegment]?) throws -> EditProject {
        var project = try AutoClipRules.project(for: candidate, media: report.media, outputAudioTracks: report.settings.exportTracks)
        project.options = options
        project.shortHook = hook
        if let captions, !captions.isEmpty {
            let transcript = SourceTranscript(mediaID: report.media.id, audioTrack: 0, language: "auto", segments: captions)
            project.transcripts = [transcript]; project.generateCaptions(from: transcript)
        }
        try project.validate()
        return project
    }
    static func uniqueFolder(in parent: URL, named name: String) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: true), index = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = parent.appendingPathComponent("\(name) \(index)", isDirectory: true); index += 1 }
        return candidate
    }
    static func fileName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return String((cleaned.isEmpty ? "Clip" : cleaned).prefix(80))
    }
}
