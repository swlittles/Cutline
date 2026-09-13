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
    var body: some Scene {
        WindowGroup(id: "editor") {
            EditorView().environmentObject(store)
                .preferredColorScheme(.dark)
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
                Button("Import Media…", action: store.importMedia).keyboardShortcut("i").disabled(store.isImporting)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project", action: { store.save() }).keyboardShortcut("s")
                Button("Save Project As…", action: { store.save(as: true) }).keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Export MP4…", action: store.exportVideo).keyboardShortcut("e").disabled(!store.canExport)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: store.undo).keyboardShortcut("z").disabled(store.undoStack.isEmpty)
                Button("Redo", action: store.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store.redoStack.isEmpty)
            }
            CommandMenu("Timeline") {
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
            }
        }
        Settings { UpdatesSettingsView(updates: updates) }
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
        store.assistantTask?.cancel()
        store.generationTask?.cancel()
        if store.isExporting || store.isImporting {
            let alert = NSAlert(); alert.messageText = "Please wait for \(store.isExporting ? "the export" : "the import") to finish."
            alert.runModal(); return false
        }
        return store.confirmDiscard()
    }
}
