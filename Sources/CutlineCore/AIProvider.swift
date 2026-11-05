import Foundation
import Security

/// Where Cutline's AI requests go. Each provider has its own API key and its own model IDs.
public enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openRouter = "openrouter"
    case claude
    public var id: String { rawValue }
    public var name: String { self == .openRouter ? "OpenRouter" : "Claude" }
    /// Who bills for the requests, for labels like "Uses your OpenRouter credits".
    public var account: String { self == .openRouter ? "OpenRouter" : "Anthropic" }
    public var keyLabel: String { self == .openRouter ? "OpenRouter API key" : "Claude API key" }
    public var keysURL: URL { URL(string: self == .openRouter ? "https://openrouter.ai/settings/keys" : "https://platform.claude.com/settings/keys")! }
    public var defaultModel: String { self == .openRouter ? EditingAssistant.defaultModel : "claude-opus-5-5" }
    /// The model a step starts on. Looking at frames sends many images per recording, so on
    /// Claude it starts on Haiku, about 40 times cheaper than Opus; the other steps start on Opus.
    public func defaultModel(for step: String) -> String {
        self == .claude && step == "vision" ? "claude-haiku-5-5" : defaultModel
    }
    public var modelExamples: String { self == .openRouter ? "google/gemini-2.5-flash" : "claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5" }
    var endpoint: URL { self == .openRouter ? EditingAssistant.endpoint : URL(string: "https://api.anthropic.com/v1/messages")! }
    var credentialService: String { self == .openRouter ? AppEnvironment.current.credentialService : AppEnvironment.current.claudeCredentialService }
    /// UI tests and the test root keep keys in a file instead of the Keychain.
    var testCredentialFile: String { self == .openRouter ? "test-credential" : "test-credential-claude" }
}

/// API keys live in the login Keychain, one entry per provider, never in project files.
public enum AIKeychain {
    private static func query(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: provider.credentialService, kSecAttrAccount as String: "api-key"]
    }
    public static func save(_ value: String, for provider: AIProvider) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw EditError.invalid("Enter \(provider == .openRouter ? "an" : "a") \(provider.keyLabel).") }
        let data = Data(key.utf8)
        if let root = LocalTools.testingRoot {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(provider.testCredentialFile), options: .atomic); return
        }
        let update = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var attributes = query(provider); attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw EditError.invalid("Could not store the API key in Keychain.") }
        } else if update != errSecSuccess { throw EditError.invalid("Could not update the API key in Keychain.") }
    }
    public static func read(_ provider: AIProvider) -> String? {
        if let root = LocalTools.testingRoot { return try? String(contentsOf: root.appendingPathComponent(provider.testCredentialFile), encoding: .utf8) }
        var request = query(provider); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func remove(_ provider: AIProvider) throws {
        if let root = LocalTools.testingRoot {
            let url = root.appendingPathComponent(provider.testCredentialFile)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EditError.invalid("Could not remove the Keychain entry.") }
    }
}
