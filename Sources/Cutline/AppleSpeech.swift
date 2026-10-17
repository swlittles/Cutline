import Foundation
import AVFoundation
import Speech
import CutlineCore

enum CaptionEngine: Equatable {
    /// whisper.cpp with a downloaded model.
    case whisper
    /// whisper.cpp is installed but no model has been downloaded yet.
    case whisperNeedsModel
    /// macOS on-device speech recognition. Nothing to install.
    case apple
    case unavailable
}

/// Captions with macOS speech recognition, forced on-device so audio never leaves the Mac.
/// Used when the optional whisper.cpp engine isn't installed.
enum AppleSpeech {
    /// Looked up once: the caption controls ask on every redraw.
    private static let recognizer: SFSpeechRecognizer? = {
        [SFSpeechRecognizer(locale: Locale.current), SFSpeechRecognizer(locale: Locale(identifier: "en-US"))]
            .compactMap { $0 }.first { $0.supportsOnDeviceRecognition }
    }()
    static var available: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return false }
        // UI tests stay deterministic and never raise the system permission prompt.
        if let root = LocalTools.testingRoot, !FileManager.default.fileExists(atPath: root.appendingPathComponent("apple-speech").path) { return false }
        return SFSpeechRecognizer.authorizationStatus() != .denied && SFSpeechRecognizer.authorizationStatus() != .restricted && recognizer != nil
    }

    static func transcribe(media: MediaItem, audioTrack: Int, range: ClipRange, progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        try await authorize()
        guard let recognizer else { throw EditError.invalid("On-device speech recognition isn’t available for your Mac’s language.") }
        let tracks = try await AVURLAsset(url: media.url).loadTracks(withMediaType: .audio)
        guard tracks.indices.contains(audioTrack) else { throw EditError.invalid("This recording has no audio track \(audioTrack + 1).") }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-speech-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Short sections keep recognition reliable and cancellation responsive.
        let chunk = 55.0
        let count = max(1, Int(ceil((range.end - range.start) / chunk)))
        var segments: [TranscriptSegment] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let start = range.start + Double(index) * chunk, length = min(chunk, range.end - start)
            guard length > 0.2 else { continue }
            let audio = workspace.appendingPathComponent("section-\(index).m4a")
            try await extract(track: tracks[audioTrack], start: start, length: length, to: audio)
            progress((Double(index) + 0.3) / Double(count))
            let words = try await recognize(audio, with: recognizer)
            segments += lines(from: words, offset: start)
            progress(Double(index + 1) / Double(count))
        }
        return segments
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        }
        guard status == .authorized else {
            throw EditError.invalid("Cutline needs permission to make captions. Open System Settings → Privacy & Security → Speech Recognition and turn on Cutline.")
        }
    }

    private static func extract(track: AVAssetTrack, start: Double, length: Double, to url: URL) async throws {
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EditError.invalid("Couldn’t read the clip’s audio.") }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        try target.insertTimeRange(range, of: track, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw EditError.invalid("Couldn’t prepare the clip’s audio.") }
        session.outputURL = url; session.outputFileType = .m4a
        await session.export()
        try Task.checkCancellation()
        guard session.status == .completed else { throw session.error ?? EditError.invalid("Couldn’t prepare the clip’s audio.") }
    }

    private struct Word: Sendable { let text: String; let start: Double; let end: Double }

    private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> [Word] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Word], Error>) in
                let once = OnceFlag()
                holder.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        guard once.claim() else { return }
                        continuation.resume(returning: result.bestTranscription.segments.map { Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) })
                    } else if let error {
                        guard once.claim() else { return }
                        // "No speech detected" is an empty result, not a failure.
                        let nsError = error as NSError
                        if nsError.domain == "kAFAssistantErrorDomain" && [1110, 203].contains(nsError.code) { continuation.resume(returning: []) }
                        else { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { holder.task?.cancel() }
    }

    /// Groups words into short caption lines: a new line after a pause, about 42 characters, or 4 seconds.
    private static func lines(from words: [Word], offset: Double) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(TranscriptSegment(start: offset + first.start, end: offset + max(last.end, first.start + 0.3), text: text)) }
            current = []
        }
        for word in words {
            if let last = current.last, let first = current.first {
                let length = current.map(\.text.count).reduce(0, +) + current.count + word.text.count
                if word.start - last.end > 0.8 || length > 42 || word.end - first.start > 4 { flush() }
            }
            current.append(word)
        }
        flush()
        return result
    }
}

private final class TaskHolder: @unchecked Sendable { var task: SFSpeechRecognitionTask? }
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
