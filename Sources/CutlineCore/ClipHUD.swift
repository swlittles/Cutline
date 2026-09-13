import Foundation
import Vision
import CoreGraphics

public struct HUDWord: Equatable, Sendable {
    public var text: String
    public var x: Double, y: Double, width: Double, height: Double, confidence: Double
    public init(_ text: String, x: Double, y: Double, width: Double, height: Double, confidence: Double = 1) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height; self.confidence = confidence
    }
}
public struct HUDRead: Equatable, Sendable {
    public var killer: String, victim: String
    public var death: Bool
}
public enum ClipHUD {
    /// Port of game's conservative name → icon-sized gap → victim rule.
    public static func parse(_ words: [HUDWord], aliases: [String]) -> [HUDRead] {
        let names = Set(aliases.map(AutoClipSettings.normalizeName).filter { !$0.isEmpty && $0 != "you" })
        let words = words.filter { $0.confidence >= 0.85 && [$0.x,$0.y,$0.width,$0.height,$0.confidence].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        var rows: [[HUDWord]] = []
        for word in words {
            if let i = rows.firstIndex(where: { abs(($0[0].y + $0[0].height / 2) - (word.y + word.height / 2)) < max(5, word.height / 2) }) { rows[i].append(word) }
            else { rows.append([word]) }
        }
        return rows.compactMap { row in
            let row = row.sorted { $0.x < $1.x }
            guard row.count > 1 else { return nil }
            for n in 1..<row.count {
                let gap = row[n].x - row[n - 1].x - row[n - 1].width
                guard gap >= max(14, row[n - 1].height * 1.2) else { continue }
                let killer = AutoClipSettings.normalizeName(row[..<n].map(\.text).joined(separator: " "))
                let victim = AutoClipSettings.normalizeName(row[n...].map(\.text).joined(separator: " "))
                guard killer != "you", victim != "you", killer != victim, !killer.contains("+"), !victim.contains("+"), victim.rangeOfCharacter(from: .letters) != nil else { continue }
                if names.contains(killer) { return HUDRead(killer: killer, victim: victim, death: false) }
                if names.contains(victim) { return HUDRead(killer: killer, victim: victim, death: true) }
            }
            return nil
        }
    }
    static func read(_ image: CGImage, aliases: [String]) throws -> [HUDRead] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]; request.customWords = aliases
        try VNImageRequestHandler(cgImage: image).perform([request])
        var words: [HUDWord] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first else { continue }
            let string = text.string
            string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byWords) { word, range, _, _ in
                guard let word, let box = try? text.boundingBox(for: range) else { return }
                let r = box.boundingBox
                words.append(HUDWord(word, x: r.minX * Double(image.width), y: (1 - r.maxY) * Double(image.height), width: r.width * Double(image.width), height: r.height * Double(image.height), confidence: Double(text.confidence)))
            }
            // A plus is meaningful (assister); don't silently discard it as word punctuation.
            if string.contains("+") { words.removeAll { abs($0.y - (1 - observation.boundingBox.maxY) * Double(image.height)) < Double(image.height) * observation.boundingBox.height } }
        }
        return parse(words, aliases: aliases)
    }
}
public struct ClipFeedTracker: Sendable {
    private struct State: Sendable { var first: Double; var last: Double; var count: Int; var emitted: Bool }
    private var rows: [String: State] = [:]
    public init() {}
    public mutating func update(at time: Double, reads: [HUDRead]) -> [ClipEvidence] {
        guard time.isFinite else { return [] }
        var events: [ClipEvidence] = []; var seen = Set<String>()
        for read in reads {
            let key = "\(read.killer)|\(read.victim)|\(read.death)"
            guard seen.insert(key).inserted else { continue }
            var state = rows[key].flatMap { time >= $0.last && time - $0.last <= 2 ? $0 : nil } ?? State(first: time, last: time, count: 0, emitted: false)
            if state.count == 0 || time > state.last { state.count += 1 }
            state.last = time
            if state.count >= 2 && !state.emitted {
                state.emitted = true
                events.append(ClipEvidence(time: state.first, signal: read.death ? .death : .elimination, detail: "HUD: \(read.killer) → \(read.victim) (repeated reads)"))
            }
            rows[key] = state
        }
        rows = rows.filter { time - $0.value.last <= 12 }
        return events
    }
}
