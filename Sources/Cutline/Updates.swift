import AppKit
import SwiftUI
import Sparkle
import CutlineCore

struct UpdateState: Equatable {
    var canCheck = false
    var automaticChecks = false
    var lastCheck: Date?
}

protocol UpdateBackend: AnyObject {
    var onChange: ((UpdateState) -> Void)? { get set }
    func start()
    func check()
    func setAutomaticChecks(_ enabled: Bool)
}

/// No backend is constructed in Dev, SwiftPM, or UI-test bundles.
final class UpdateService: ObservableObject {
    @Published private(set) var state = UpdateState()
    let enabled: Bool
    private var backend: UpdateBackend?
    private let makeBackend: () -> UpdateBackend
    init(environment: AppEnvironment = .current, makeBackend: @escaping () -> UpdateBackend = { SparkleBackend() }) {
        enabled = !environment.isDevelopment; self.makeBackend = makeBackend
    }
    func start() {
        guard enabled, backend == nil else { return }
        let backend = makeBackend(); self.backend = backend
        backend.onChange = { [weak self] state in self?.state = state }
        backend.start()
    }
    func check() { guard enabled, state.canCheck else { return }; backend?.check() }
    func setAutomaticChecks(_ value: Bool) { guard enabled else { return }; backend?.setAutomaticChecks(value) }
}

private final class SparkleBackend: NSObject, UpdateBackend {
    var onChange: ((UpdateState) -> Void)?
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in self?.refresh() },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in self?.refresh() },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in self?.refresh() }
        ]
        controller.startUpdater()
    }
    private func refresh() {
        guard let updater = controller?.updater else { return }
        onChange?(UpdateState(canCheck: updater.canCheckForUpdates, automaticChecks: updater.automaticallyChecksForUpdates, lastCheck: updater.lastUpdateCheckDate))
    }
    func check() { NSApp.activate(ignoringOtherApps: true); controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
}

struct UpdatesSettingsView: View {
    @ObservedObject var updates: UpdateService
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(AppEnvironment.current.name) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.title2)
            if updates.enabled {
                Toggle("Automatically check for updates", isOn: Binding(get: { updates.state.automaticChecks }, set: updates.setAutomaticChecks)).accessibilityIdentifier("updates.automatic")
                Text("Updates come from Cutline’s GitHub releases. You choose when to download and install them.")
                if Bundle.main.object(forInfoDictionaryKey: "CutlineReleaseChannel") as? String == "preview" {
                    Text("Developer preview: this build is not notarized by Apple.").foregroundStyle(.orange)
                }
                Button("Check for Updates…", action: updates.check).disabled(!updates.state.canCheck).accessibilityIdentifier("updates.check")
                Text(updates.state.lastCheck.map { "Last checked: \($0.formatted())" } ?? "No update checks yet.").font(.caption)
            } else {
                Text("This is a local development build. Rebuild it from the dev branch to update. It never checks for or installs release updates.").accessibilityIdentifier("updates.development")
            }
            if let address = Bundle.main.object(forInfoDictionaryKey: "CutlineReleasesURL") as? String, let url = URL(string: address) { Link("GitHub releases and downloads", destination: url) }
        }.padding(24).frame(width: 450).onAppear { updates.start() }
    }
}
