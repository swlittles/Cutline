import Foundation

/// Unknown bundles and unbundled command-line executions are always development builds.
public struct AppEnvironment: Equatable, Sendable {
    public let isDevelopment: Bool
    public init(bundleIdentifier: String?) { isDevelopment = bundleIdentifier != "studio.cutline.editor" }
    public var name: String { isDevelopment ? "Cutline Dev" : "Cutline" }
    public var bundleIdentifier: String { isDevelopment ? "studio.cutline.editor.dev" : "studio.cutline.editor" }
    public var credentialService: String { isDevelopment ? "studio.cutline.dev.openrouter" : "studio.cutline.openrouter" }
    public func supportURL(root: URL) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    /// "Cutline 0.5.1" or "Cutline Dev 0.5.1". A build without a version says it is a local build.
    public func versionLabel(_ version: String?) -> String {
        guard let version, !version.isEmpty else { return "\(name) (local build)" }
        return "\(name) \(version)"
    }
    public static var currentVersionLabel: String { current.versionLabel(hostBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) }
    public static let current = AppEnvironment(bundleIdentifier: hostBundle.bundleIdentifier)
    /// The app this code ships in. The agent connector sits in the app's Contents/MacOS, where
    /// `Bundle.main` is just the executable's folder, so it shares the app's settings through this.
    public static let hostBundle: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app", executable.deletingLastPathComponent().lastPathComponent == "MacOS", let bundle = Bundle(url: app) { return bundle }
        return Bundle.main
    }()
}
