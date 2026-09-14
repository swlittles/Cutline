import Foundation

/// A local creator preference, deliberately excluded from portable project documents.
public struct ShortBranding: Codable, Hashable, Sendable {
    public enum Logo: String, Codable, CaseIterable, Sendable { case none, kick }
    public var text: String
    public var logo: Logo
    public init(text: String = "", logo: Logo = .none) { self.text = text; self.logo = logo }
    public var displayText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public func validate(required: Bool = true) throws {
        guard (!required || !displayText.isEmpty), text.count <= 80, !text.contains(where: { $0.isNewline || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw EditError.invalid("Set your short branding in Settings: 1–80 characters on one line. It is saved only on this Mac.")
        }
    }
}

public enum CreatorProfileStore {
    public static func load(from root: URL = LocalTools.support) throws -> ShortBranding {
        let url = root.appendingPathComponent("creator-profile.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ShortBranding() }
        let value = try JSONDecoder().decode(ShortBranding.self, from: Data(contentsOf: url))
        try value.validate(required: false)
        return value
    }
    public static func save(_ profile: ShortBranding, to root: URL = LocalTools.support) throws {
        try profile.validate(required: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("creator-profile.json")
        let temporary = root.appendingPathComponent(".creator-profile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(profile), attributes: [.posixPermissions: 0o600]) else {
            throw EditError.invalid("Could not save the local creator profile.")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: target) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
