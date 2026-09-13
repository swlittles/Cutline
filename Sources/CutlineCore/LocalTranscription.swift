import Foundation
import CryptoKit
import Darwin

public enum LocalTools {
    /// Debug-only test sandbox. Release builds always use normal Application Support.
    public static var testingRoot: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["CUTLINE_TEST_ROOT"], path.hasPrefix("/"), URL(fileURLWithPath: path).lastPathComponent.hasPrefix("cutline-test-") { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        return nil
    }

    public static var support: URL { if let root = testingRoot { return root }; return AppEnvironment.current.supportURL(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) }
    public static func executable(_ name: String) -> URL? {
        if let root = testingRoot {
            let helper = root.appendingPathComponent("Helpers/\(name)")
            if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        }
        let paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public static func require(_ name: String) throws -> URL {
        guard let url = executable(name) else { throw EditError.invalid("\(name) is not installed. Run scripts/setup-local-ai.sh from the Cutline folder, then try again.") }
        return url
    }
}

public enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case base, baseEnglish = "base.en", smallEnglish = "small.en"
    public var id: String { rawValue }
    public var label: String {
        switch self { case .base: return "Base · multilingual · 148 MB"; case .baseEnglish: return "Base · English · 148 MB"; case .smallEnglish: return "Small · English · 488 MB" }
    }
    public var checksum: String {
        switch self {
        case .base: return "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .baseEnglish: return "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        case .smallEnglish: return "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
        }
    }
    public var file: URL { LocalTools.support.appendingPathComponent("Models/ggml-\(rawValue).bin") }
    public var installed: Bool { FileManager.default.fileExists(atPath: file.path) }
    public func download() async throws {
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue).bin")!
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EditError.invalid("Model download failed. Check your connection and try again.") }
        let hash = try await Task.detached { () -> String in
            let handle = try FileHandle(forReadingFrom: temporary); defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        try Task.checkCancellation()
        guard hash == checksum else { throw EditError.invalid("The model download failed its integrity check. Please retry.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if installed { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: file) }
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process; try process.run()
    }
    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning {
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
}

public enum ProcessRunner {
    /// Uses argv directly, never a shell. Disk-backed output prevents pipe deadlocks.
    public static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            do {
            let result = try await Task.detached { () throws -> String in
                let log = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-process-\(UUID()).log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
                let process = Process(); process.executableURL = executable; process.arguments = arguments
                process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
                try running.start(process); process.waitUntilExit()
                let reader = try FileHandle(forReadingFrom: log); defer { try? reader.close() }
                let length = try reader.seekToEnd(); try reader.seek(toOffset: length > 16384 ? length - 16384 : 0)
                let output = String(data: try reader.readToEnd() ?? Data(), encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else { throw EditError.invalid("\(executable.lastPathComponent) failed (\(process.terminationStatus)).\n\(output.suffix(1800))") }
                return output
            }.value
            try Task.checkCancellation()
            return result
            } catch { try Task.checkCancellation(); throw error }
        } onCancel: { running.cancel() }
    }
}

public struct TranscriptionProgress: Sendable {
    public var fraction: Double
    public var message: String
}

public enum LocalTranscription {
    public static func transcribe(media: MediaItem, audioTrack: Int, model: WhisperModel, language: String = "auto", vocabulary: String = "", progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> SourceTranscript {
        let whisper = try LocalTools.require("whisper-cli"), ffmpeg = try LocalTools.require("ffmpeg")
        guard model.installed else { throw EditError.invalid("Download a speech model in the Captions panel first.") }
        guard audioTrack >= 0 else { throw EditError.invalid("Choose a valid audio track.") }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-transcribe-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Bound memory and make cancellation responsive even for multi-hour streams.
        let chunkDuration = 300.0
        let count = max(1, Int(ceil(media.duration / chunkDuration)))
        var segments: [TranscriptSegment] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let start = Double(index) * chunkDuration
            let length = min(chunkDuration, media.duration - start)
            let wav = workspace.appendingPathComponent("chunk.wav"), output = workspace.appendingPathComponent("transcript")
            progress(.init(fraction: Double(index) / Double(count), message: "Decoding \(media.name) · section \(index + 1)/\(count)"))
            _ = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", String(start), "-i", media.url.path, "-t", String(length), "-map", "0:a:\(audioTrack)", "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path])
            progress(.init(fraction: (Double(index) + 0.15) / Double(count), message: "Transcribing locally · section \(index + 1)/\(count)"))
            var args = ["-m", model.file.path, "-f", wav.path, "-l", model == .base ? language : "en", "-t", "4", "-osrt", "-of", output.path, "-ml", "42", "-sow", "-sns"]
            if !vocabulary.isEmpty { args += ["--prompt", String(vocabulary.prefix(1000))] }
            _ = try await ProcessRunner.run(whisper, args)
            let subtitle = try String(contentsOf: output.appendingPathExtension("srt"), encoding: .utf8)
            if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let decoded = try SubtitleFile.decode(subtitle)
                segments += decoded.compactMap { segment in
                    let low = max(0, segment.start), high = min(length, segment.end)
                    guard high > low else { return nil }
                    return TranscriptSegment(start: low + start, end: high + start, text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        progress(.init(fraction: 1, message: "Transcription complete · \(segments.count) captions"))
        return SourceTranscript(mediaID: media.id, audioTrack: audioTrack, language: model == .base ? language : "en", segments: segments)
    }
}
