import Foundation

public enum AutoClipBatch {
    /// Each successful batch is a new directory. Failures and cancellation leave no half-published batch.
    public static func export(report: AutoClipReport, candidates: [AutoClipCandidate], to parent: URL, options: ProjectSettings = ProjectSettings(), progress: @escaping @Sendable (ClipScanProgress) -> Void = { _ in }) async throws -> URL {
        guard parent.isFileURL, !candidates.isEmpty, candidates.count <= 100 else { throw EditError.invalid("Select clips and a local output folder.") }
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".cutline-clips-\(token)", isDirectory: true)
        let destination = parent.appendingPathComponent("Cutline clips \(token.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var exported = report; exported.candidates = candidates
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            var project = try AutoClipRules.project(for: candidate, media: report.media, outputAudioTrack: report.settings.outputAudioTrack)
            project.options = options
            let stem = String(format: "%02d", index + 1) + " - " + candidate.title.replacingOccurrences(of: ":", with: "-")
            let render = try await CompositionEngine.build(project)
            try await CompositionEngine.export(render, to: staging.appendingPathComponent(stem + ".mp4")) { value in
                progress(ClipScanProgress((Double(index) + value) / Double(candidates.count), "Exporting clip \(index + 1) of \(candidates.count)…"))
            }
            try project.write(to: staging.appendingPathComponent(stem + ".cutline"))
        }
        try encoder.encode(exported).write(to: staging.appendingPathComponent("analysis.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
        progress(ClipScanProgress(1, "Exported \(candidates.count) \(candidates.count == 1 ? "clip" : "clips")."))
        return destination
    }
}
