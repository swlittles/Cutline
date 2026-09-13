import Foundation

/// Unknown bundles and unbundled command-line executions are always development builds.
public struct AppEnvironment: Equatable, Sendable {
    public let isDevelopment: Bool
    public init(bundleIdentifier: String?) { isDevelopment = bundleIdentifier != "studio.cutline.editor" }
    public var name: String { isDevelopment ? "Cutline Dev" : "Cutline" }
    public var bundleIdentifier: String { isDevelopment ? "studio.cutline.editor.dev" : "studio.cutline.editor" }
    public var credentialService: String { isDevelopment ? "studio.cutline.dev.openrouter" : "studio.cutline.openrouter" }
    public func supportURL(root: URL) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    public static let current = AppEnvironment(bundleIdentifier: Bundle.main.bundleIdentifier)
}
