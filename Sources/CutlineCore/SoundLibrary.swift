import Foundation
import AVFoundation

/// One sound in the library, such as an impact or a whoosh.
public struct SoundEffect: Codable, Identifiable, Hashable, Sendable {
    /// "<category>/<file>", e.g. "impact/boom.wav". Also its path inside the library folder.
    public var id: String
    public var name: String
    public var category: String
    public var url: URL
    public var duration: Double
    public init(id: String, name: String, category: String, url: URL, duration: Double) {
        self.id = id; self.name = name; self.category = category; self.url = url; self.duration = duration
    }
}

/// Sound effects kept in Cutline's own Application Support folder, so they're always there to add
/// to clips. Cutline ships no sounds of its own: import files, or a pack folder laid out as
/// `<category>/<file>` with an optional `sounds.json` of display names (`{"impact/boom.wav": {"label": "Boom"}}`).
public enum SoundLibrary {
    public static let categories = ["impact", "whoosh", "riser", "pop", "other"]
    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"]
    static let labelsFile = "sounds.json"
    /// Longer files are music, not effects; they belong in Add music / audio.
    public static let longestSound = 30.0

    public static func folder(root: URL = LocalTools.support) -> URL { root.appendingPathComponent("Sounds", isDirectory: true) }
    public static func title(_ category: String) -> String {
        switch category {
        case "impact": return "Impacts"
        case "whoosh": return "Whooshes"
        case "riser": return "Risers"
        case "pop": return "Pops"
        case "other": return "Other"
        default: return label(fromFile: category)
        }
    }
    /// "vine-boom.wav" → "Vine boom".
    static func label(fromFile file: String) -> String {
        let stem = (file as NSString).deletingPathExtension.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? file : stem.prefix(1).uppercased() + stem.dropFirst()
    }
    static func isAudio(_ url: URL) -> Bool { !url.lastPathComponent.hasPrefix(".") && audioExtensions.contains(url.pathExtension.lowercased()) }
    /// A category is one plain folder name: lowercase letters, digits and dashes.
    static func category(_ name: String) -> String {
        let cleaned = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "other" : String(cleaned.prefix(40))
    }

    /// Every sound in the library, sorted by category, then name. Files that can't be read as audio are left out.
    public static func sounds(root: URL = LocalTools.support) async -> [SoundEffect] {
        let base = folder(root: root), labels = readLabels(base)
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [SoundEffect] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for file in files where isAudio(file) {
                let id = "\(folder.lastPathComponent)/\(file.lastPathComponent)"
                guard let duration = try? await AVURLAsset(url: file).load(.duration).seconds, duration.isFinite, duration > 0 else { continue }
                result.append(SoundEffect(id: id, name: labels[id] ?? label(fromFile: file.lastPathComponent), category: folder.lastPathComponent, url: file, duration: duration))
            }
        }
        let order = { (category: String) in categories.firstIndex(of: category) ?? categories.count }
        return result.sorted { (order($0.category), $0.category, $0.name.lowercased()) < (order($1.category), $1.category, $1.name.lowercased()) }
    }

    /// Copies audio files into one category. A file whose name is taken gets a number. Returns how many were added.
    @discardableResult
    public static func add(_ files: [URL], category: String, root: URL = LocalTools.support) throws -> Int {
        let target = folder(root: root).appendingPathComponent(self.category(category), isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var added = 0
        for file in files where isAudio(file) {
            try FileManager.default.copyItem(at: file, to: unique(file.lastPathComponent, in: target)); added += 1
        }
        guard added > 0 || files.isEmpty else { throw EditError.invalid("Choose WAV, MP3, M4A, AIFF, CAF or FLAC files.") }
        return added
    }

    /// Copies a pack folder: each subfolder is a category and loose files go to Other. Display
    /// names from the pack's `sounds.json` come along. A sound already in the library is replaced.
    @discardableResult
    public static func importPack(_ pack: URL, root: URL = LocalTools.support) throws -> Int {
        let manager = FileManager.default, base = folder(root: root)
        let entries = try manager.contentsOfDirectory(at: pack, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var labels = readLabels(base), packLabels = readLabels(pack), added = 0
        func copy(_ file: URL, into category: String, packID: String) throws {
            let target = base.appendingPathComponent(category, isDirectory: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            let destination = target.appendingPathComponent(file.lastPathComponent)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: file, to: destination)
            if let name = packLabels[packID] { labels["\(category)/\(file.lastPathComponent)"] = name }
            added += 1
        }
        for entry in entries {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // Folders whose names start with "_" hold working files, such as originals.
                guard !entry.lastPathComponent.hasPrefix("_") else { continue }
                let files = try manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                for file in files where isAudio(file) { try copy(file, into: category(entry.lastPathComponent), packID: "\(entry.lastPathComponent)/\(file.lastPathComponent)") }
            } else if isAudio(entry) {
                try copy(entry, into: "other", packID: entry.lastPathComponent)
            }
        }
        guard added > 0 else { throw EditError.invalid("That folder has no sounds. Put audio files in it, or in subfolders such as impact and whoosh.") }
        try writeLabels(labels, to: base)
        return added
    }

    public static func remove(_ sound: SoundEffect, root: URL = LocalTools.support) throws {
        let base = folder(root: root)
        // Only ever delete inside the library.
        guard sound.url.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path + "/") else { throw EditError.invalid("That sound isn't in the library.") }
        if FileManager.default.fileExists(atPath: sound.url.path) { try FileManager.default.removeItem(at: sound.url) }
        var labels = readLabels(base); labels[sound.id] = nil; try writeLabels(labels, to: base)
    }

    static func unique(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name), index = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = folder.appendingPathComponent("\(stem) \(index).\(ext)"); index += 1 }
        return candidate
    }
    /// id → display name. Other fields a pack's file may carry are ignored.
    static func readLabels(_ folder: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(labelsFile)),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return entries.reduce(into: [:]) { result, entry in
            if let label = ((entry.value as? [String: Any])?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { result[entry.key] = label }
        }
    }
    static func writeLabels(_ labels: [String: String], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: labels.mapValues { ["label": $0] }, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent(labelsFile), options: .atomic)
    }
}

public extension AudioClip {
    /// A sound effect placed at `start`, at full length.
    init(sound: SoundEffect, start: Double, volume: Double = 0.8) {
        self.init(url: sound.url, start: max(0, start), duration: sound.duration)
        self.volume = volume; label = sound.name
    }
}
