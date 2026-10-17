import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let cutlineProject = UTType(exportedAs: "studio.cutline.project", conformingTo: .json)
}

@main
struct CutlineApp: App {
    @StateObject private var store = EditorStore()
    @StateObject private var updates = UpdateService()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.system.rawValue
    @AppStorage("editor-advanced") private var advancedEditor = false
    var body: some Scene {
        WindowGroup(id: "editor") {
            RootView().environmentObject(store)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    guard !store.isImporting, !store.isExporting, store.confirmDiscard() else { return }
                    store.loadProject(url)
                }
                .onAppear {
                    #if DEBUG
                    UITestRuntime.install()
                    #endif
                    delegate.store = store
                    AppearanceMode.apply(.current)
                    updates.start()
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    if let index = CommandLine.arguments.firstIndex(of: "--project"), CommandLine.arguments.count > index + 1, store.projectURL == nil {
                        store.loadProject(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updates.check).disabled(!updates.enabled || !updates.state.canCheck)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project", action: store.newProject).keyboardShortcut("n").disabled(store.isImporting)
                Button("Open Project…", action: store.openProject).keyboardShortcut("o").disabled(store.isImporting)
                Button("Recover Autosave", action: store.recoverAutosave)
                Button("Import Media…", action: { store.mode == .clipper ? store.chooseVODFromPanel() : store.importMedia() }).keyboardShortcut("i").disabled(store.isImporting)
                Divider()
                Button("Clip a Stream…", action: store.startClipping).keyboardShortcut("n", modifiers: [.command, .shift]).disabled(store.isImporting)
                Button("Home", action: store.showHome).keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0; AppearanceMode.apply(AppearanceMode(rawValue: $0) ?? .system) })) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Show Advanced Editing Tools", isOn: $advancedEditor)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project", action: { store.save() }).keyboardShortcut("s")
                Button("Save Project As…", action: { store.save(as: true) }).keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Export MP4…", action: store.exportVideo).keyboardShortcut("e").disabled(!store.canExport || store.mode != .editor)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: store.undo).keyboardShortcut("z").disabled(store.undoStack.isEmpty)
                Button("Redo", action: store.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store.redoStack.isEmpty)
            }
            CommandMenu("Timeline") {
                // Timeline keys belong to the editor. The clipper's review screen handles its own keys.
                Group {
                    Button("Play / Pause", action: store.togglePlayback).keyboardShortcut(.space, modifiers: [])
                    Button("Mark Highlight", action: store.addMarker).keyboardShortcut("m", modifiers: [.command, .shift])
                    Button("Split at Playhead", action: store.split).keyboardShortcut("b").disabled(store.project.clips.isEmpty)
                    Button("Duplicate Clip", action: store.duplicate).keyboardShortcut("d").disabled(store.selectedClip == nil)
                    Button("Delete Clip", action: store.deleteSelected).disabled(store.selectedClip == nil)
                    Divider()
                    Button("Back 5 Seconds", action: { store.seek(store.playhead - 5) }).keyboardShortcut(.leftArrow, modifiers: [])
                    Button("Forward 5 Seconds", action: { store.seek(store.playhead + 5) }).keyboardShortcut(.rightArrow, modifiers: [])
                    Button("Previous Frame", action: { store.seek(store.playhead - 1.0 / Double(store.project.options.fps)) }).keyboardShortcut(.leftArrow, modifiers: .option)
                    Button("Next Frame", action: { store.seek(store.playhead + 1.0 / Double(store.project.options.fps)) }).keyboardShortcut(.rightArrow, modifiers: .option)
                }.disabled(store.mode != .editor)
            }
        }
        Settings { UpdatesSettingsView(updates: updates).environmentObject(store).tint(Studio.accent) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var store: EditorStore?
    private var closeApproved = false
    func applicationDidBecomeActive(_ notification: Notification) {
        // Never replace a file panel's own delegate; it manages file selection.
        NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }.forEach { $0.delegate = self }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeApproved = mayClose(); return closeApproved }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { (closeApproved || mayClose()) ? .terminateNow : .terminateCancel }
    private func mayClose() -> Bool {
        guard let store else { return true }
        if store.isTranscribing { store.transcriptionTask?.cancel() }
        store.clipTask?.cancel()
        store.clipCaptionTask?.cancel()
        store.assistantTask?.cancel()
        store.generationTask?.cancel()
        if store.isExporting || store.isExportingClips || store.isImporting {
            let alert = NSAlert(); alert.messageText = "Please wait for \((store.isExporting || store.isExportingClips) ? "the export" : "the import") to finish."
            alert.runModal(); return false
        }
        return store.confirmDiscard()
    }
}
