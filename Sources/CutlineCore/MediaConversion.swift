import Foundation
import UniformTypeIdentifiers

/// OBS records MKV by default, which AVFoundation can't open. Copying the streams into
/// an MP4 container is lossless and fast (no re-encoding), the same as OBS's Remux.
public enum MediaConversion {
    public static let convertibleExtensions: Set<String> = ["mkv", "flv", "ts"]
    public static var convertibleTypes: [UTType] { convertibleExtensions.compactMap { UTType(filenameExtension: $0) } }
    public static func needsConversion(_ url: URL) -> Bool { convertibleExtensions.contains(url.pathExtension.lowercased()) }

    /// Explains how to convert in OBS when the bundled/installed converter is missing.
    public static func missingConverterMessage(_ url: URL) -> String {
        "Cutline can’t open \(url.lastPathComponent) directly. In OBS, choose File → Remux Recordings to make an MP4 copy, then choose that file.\n\nTip: in OBS Settings → Advanced → Recording, turn on “Automatically remux to MP4” so this never comes up again."
    }

    /// The MP4 beside the original. An MP4 that OBS (or an earlier import) already made is reused.
    public static func destination(for url: URL) -> (url: URL, existing: Bool) {
        let sibling = url.deletingPathExtension().appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: sibling.path) { return (sibling, true) }
        let folder = url.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: folder.path) { return (sibling, false) }
        let fallback = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/Converted", isDirectory: true)
        return (fallback.appendingPathComponent(sibling.lastPathComponent), FileManager.default.fileExists(atPath: fallback.appendingPathComponent(sibling.lastPathComponent).path))
    }

    public static func convertToMP4(_ url: URL) async throws -> URL {
        let target = destination(for: url)
        if target.existing { return target.url }
        guard let ffmpeg = LocalTools.executable("ffmpeg") else { throw EditError.invalid(missingConverterMessage(url)) }
        try FileManager.default.createDirectory(at: target.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.url.deletingLastPathComponent().appendingPathComponent(".\(target.url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        // Every video and audio stream, copied as-is. OBS multitrack audio stays intact.
        _ = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", url.path, "-map", "0:v", "-map", "0:a?", "-c", "copy", "-movflags", "+faststart", partial.path])
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: target.url)
        return target.url
    }
}
