import XCTest
import AVFoundation
@testable import CutlineCore

final class LocalSpeechTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Models"), withIntermediateDirectories: true)
        setenv("CUTLINE_TEST_ROOT", root.path, 1)
        guard LocalTools.testingRoot?.path == root.path else { throw XCTSkip("Test isolation requires a Debug build") }
        XCTAssertEqual(LocalTools.support.path, root.path)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root); unsetenv("CUTLINE_TEST_ROOT") }
    private func install(fail: Bool = false) throws {
        for model in [WhisperModel.base, .baseEnglish] { try Data("fixture".utf8).write(to: model.file) }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$CUTLINE_TEST_ROOT/arguments"
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -f) shift; input="$1" ;;
            -of) shift; output="$1" ;;
          esac
          shift
        done
        printf '%s' "$input" > "$CUTLINE_TEST_ROOT/workspace"
        cp "$input" "$CUTLINE_TEST_ROOT/captured.wav"
        \(fail ? "echo 'Speech fixture failure' >&2; exit 9" : "true")
        cat > "$output.srt" <<'SRT'
        1
        00:00:00,300 --> 00:00:01,400
        Local microphone caption.
        SRT
        """
        let file = root.appendingPathComponent("Helpers/whisper-cli")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    private func source() -> MediaItem { MediaItem(url: Fixtures.directory.appendingPathComponent("gameplay.mp4"), duration: 5) }
    func testSelectedOBSTrackIsActuallyExtractedAsMono16KHz() async throws {
        try install()
        let transcript = try await LocalTranscription.transcribe(media: source(), audioTrack: 1, model: .base, progress: { _ in })
        XCTAssertEqual(transcript.audioTrack, 1); XCTAssertEqual(transcript.segments.first?.text, "Local microphone caption.")
        let file = try AVAudioFile(forReading: root.appendingPathComponent("captured.wav"))
        XCTAssertEqual(file.processingFormat.sampleRate, 16000); XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0], count = Int(buffer.frameLength)
        let crossings = (1..<count).filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }.count
        let frequency = Double(crossings) / (Double(count) / 16000)
        XCTAssertEqual(frequency, 880, accuracy: 3, "Audio 2 contains 880 Hz; audio 1 contains 440 Hz")
        let workspace = try String(contentsOf: root.appendingPathComponent("workspace"), encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: workspace).deletingLastPathComponent().path))
    }
    func testEnglishModelForcesEnglishAndBoundsVocabularyWithoutShellExpansion() async throws {
        try install()
        let words = "$(touch never-created) " + String(repeating: "x", count: 1100)
        _ = try await LocalTranscription.transcribe(media: source(), audioTrack: 0, model: .baseEnglish, language: "es", vocabulary: words, progress: { _ in })
        let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-l")! + 1], "en")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--prompt")! + 1], String(words.prefix(1000)))
    }
    func testFailedSpeechProcessCleansDecodedAudio() async throws {
        try install(fail: true)
        do { _ = try await LocalTranscription.transcribe(media: source(), audioTrack: 0, model: .base, progress: { _ in }); XCTFail("Expected speech failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Speech fixture failure")) }
        let workspace = try String(contentsOf: root.appendingPathComponent("workspace"), encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: workspace).deletingLastPathComponent().path))
    }
    func testMissingModelAndNegativeTrackAreActionable() async throws {
        try install(); try FileManager.default.removeItem(at: WhisperModel.base.file)
        do { _ = try await LocalTranscription.transcribe(media: source(), audioTrack: 0, model: .base, progress: { _ in }); XCTFail("Expected missing model") }
        catch { XCTAssertTrue(error.localizedDescription.contains("speech model")) }
        try install()
        do { _ = try await LocalTranscription.transcribe(media: source(), audioTrack: -1, model: .base, progress: { _ in }); XCTFail("Expected invalid track") }
        catch { XCTAssertTrue(error.localizedDescription.contains("valid audio track")) }
    }
    func testInvalidTrackNeverReplacesCaptionsWithFabricatedSpeech() async throws {
        try install()
        do { _ = try await LocalTranscription.transcribe(media: source(), audioTrack: 8, model: .base, progress: { _ in }); XCTFail("Accepted absent OBS audio track") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ffmpeg failed")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path))
    }
}
