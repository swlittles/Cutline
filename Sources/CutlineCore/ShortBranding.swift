import Foundation

/// A local creator preference, deliberately excluded from portable project documents:
/// the creator's Kick and Twitch usernames, which platform's badge shorts carry, and where.
public struct ShortBranding: Codable, Hashable, Sendable {
    public enum Platform: String, Codable, CaseIterable, Identifiable, Sendable {
        case kick, twitch
        public var id: String { rawValue }
        public var label: String { self == .kick ? "Kick" : "Twitch" }
        public var site: String { self == .kick ? "kick.com/" : "twitch.tv/" }
    }
    public var kick: String
    public var twitch: String
    /// Which platform's logo container appears on shorts.
    public var badge: Platform
    public var placement: BadgePlacement
    public init(kick: String = "", twitch: String = "", badge: Platform = .kick, placement: BadgePlacement = BadgePlacement()) {
        self.kick = Self.username(kick); self.twitch = Self.username(twitch); self.badge = badge; self.placement = placement
    }

    public func username(for platform: Platform) -> String { Self.username(platform == .kick ? kick : twitch) }
    /// The handle drawn in the badge, such as "@blankmantv". Empty until the chosen platform has a username.
    public var displayText: String { username(for: badge).isEmpty ? "" : "@" + username(for: badge) }

    /// Accepts "name", "@name" or a pasted channel address, and keeps just the name.
    public static func username(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "kick.com/", "twitch.tv/", "@"] where value.lowercased().hasPrefix(prefix) { value.removeFirst(prefix.count) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    public func validate(required: Bool = true) throws {
        for platform in Platform.allCases {
            let name = username(for: platform)
            guard !name.isEmpty else { continue }
            guard name.count <= 40, name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) }) else {
                throw EditError.invalid("Your \(platform.label) username can use letters, numbers, dots, dashes and underscores (up to 40).")
            }
        }
        guard placement.valid else { throw EditError.invalid("Keep the channel badge inside the short.") }
        if required && displayText.isEmpty {
            throw EditError.invalid("Add your \(badge.label) username in Settings → Your channel. Shorts show it in the \(badge.label) badge. It is saved only on this Mac.")
        }
    }

    enum CodingKeys: String, CodingKey { case kick, twitch, badge, placement, text, logo }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.badge) || c.contains(.kick) || c.contains(.twitch) {
            self.init(kick: try c.decodeIfPresent(String.self, forKey: .kick) ?? "", twitch: try c.decodeIfPresent(String.self, forKey: .twitch) ?? "",
                      badge: try c.decodeIfPresent(Platform.self, forKey: .badge) ?? .kick, placement: try c.decodeIfPresent(BadgePlacement.self, forKey: .placement) ?? BadgePlacement())
            return
        }
        // Profiles before badges held one line of text and an optional Kick logo.
        let original = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        let text = String(Self.username(original).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) }.prefix(40))
        let logo = try c.decodeIfPresent(String.self, forKey: .logo)
        let twitch = original.lowercased().contains("twitch.tv/") && logo != "kick"
        self.init(kick: twitch ? "" : text, twitch: twitch ? text : "", badge: twitch ? .twitch : .kick)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(username(for: .kick), forKey: .kick); try c.encode(username(for: .twitch), forKey: .twitch); try c.encode(badge, forKey: .badge); try c.encode(placement, forKey: .placement)
    }
}

/// Where the badge sits on a short: its centre as fractions of the frame from the top-left,
/// and its size relative to the standard badge (4% of the frame's height).
public struct BadgePlacement: Codable, Hashable, Sendable {
    public static let standardHeight = 76.0 / 1920
    public static let sizes = 0.5...2.5
    public var x: Double
    public var y: Double
    public var size: Double
    /// Centred on the strip between facecam and gameplay.
    public init(x: Double = 0.5, y: Double = 0.31, size: Double = 1) { self.x = x; self.y = y; self.size = size }
    public var valid: Bool { [x, y, size].allSatisfy(\.isFinite) && (0...1).contains(x) && (0...1).contains(y) && Self.sizes.contains(size) }
    /// The badge's rectangle on a canvas, from the top-left, kept fully inside the frame.
    public func rect(badge: CGSize, canvas: CGSize) -> CGRect {
        let width = min(badge.width, canvas.width), height = min(badge.height, canvas.height)
        // Whole pixels keep the badge crisp.
        let left = min(max(0, x * canvas.width - width / 2), canvas.width - width).rounded(.down)
        let top = min(max(0, y * canvas.height - height / 2), canvas.height - height).rounded(.down)
        return CGRect(x: left, y: top, width: width, height: height)
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
