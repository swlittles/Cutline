import Foundation

public enum ExportDestination {
    /// Commits only a successful render, preserving an existing destination on failure or cancellation.
    public static func write(to destination: URL, protecting sources: [URL] = [], render: (URL) async throws -> Void) async throws {
        guard destination.isFileURL else { throw EditError.invalid("Choose a local export destination.") }
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !sources.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == resolved }) else { throw EditError.invalid("Choose a different export filename to preserve your source media.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".cutline-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try await render(temporary)
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: temporary.path) else { throw EditError.invalid("The renderer did not produce an output file.") }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }
}
