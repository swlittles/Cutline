import SwiftUI
import CutlineCore

// MARK: - Following edits made by agents

extension EditorStore {
    static func modificationDate(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }

    /// Agents (through Cutline's connector) edit the project file directly. The open project
    /// follows those edits, and Undo takes each one back.
    func followProjectFile() {
        guard mode == .editor, let url = projectURL, !isImporting, !isExporting, !isOfferingReload,
              let date = Self.modificationDate(url), date != projectFileDate else { return }
        projectFileDate = date
        guard let disk = try? EditProject.read(from: url), disk != savedProject else { return }
        if dirty {
            isOfferingReload = true; defer { isOfferingReload = false }
            let alert = NSAlert()
            alert.messageText = "“\(disk.name)” was changed outside Cutline"
            alert.informativeText = "An AI agent or another app saved changes to this project. Load them? Your unsaved changes here are replaced, and Undo brings them back."
            alert.addButton(withTitle: "Load Changes"); alert.addButton(withTitle: "Keep Mine")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let known = Set(project.media.map(\.id))
        undoStack.append(project)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        project = disk; savedProject = disk
        if let id = selectedClipID, !disk.clips.contains(where: { $0.id == id }) { selectedClipID = nil }
        rebuild()
        status = "Updated by an AI agent. Press ⌘Z to undo."
        Task { for item in disk.media where !known.contains(item.id) { await loadThumbnail(item) } }
    }
}

// MARK: - Connecting agents

/// One AI coding agent that can use Cutline through its connector.
enum AgentClient: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    /// The connector ships inside the app, beside the main executable.
    static var connector: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cutline-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    static var serverName: String { AppEnvironment.current.isDevelopment ? "cutline-dev" : "cutline" }
    func command(_ connector: URL) -> String {
        let path = "'" + connector.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch self {
        case .claude: return "claude mcp add --scope user \(Self.serverName) -- \(path)"
        case .codex: return "codex mcp add \(Self.serverName) -- \(path)"
        }
    }
    /// Whether the agent's command-line tool is installed, as Terminal would find it.
    func isInstalled() async -> Bool {
        // Tests never look for, or change, this Mac's real agents.
        guard LocalTools.testingRoot == nil else { return false }
        let result = await Self.shell("command -v \(self == .claude ? "claude" : "codex")", timeout: 10)
        return result.status == 0 && result.output.split(separator: "\n").contains { $0.hasPrefix("/") }
    }
    func connect(_ connector: URL) async throws {
        guard LocalTools.testingRoot == nil else { throw EditError.invalid("Connecting is turned off in tests.") }
        let result = await Self.shell(command(connector))
        // Adding twice is fine: the agent already has Cutline.
        guard result.status == 0 || result.output.localizedCaseInsensitiveContains("already exists") else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EditError.invalid(detail.isEmpty ? "\(name) couldn’t add Cutline. Copy the command and run it in Terminal instead." : String(detail.suffix(300)))
        }
    }
    /// Apps opened from Finder don't get the shell's PATH, so run commands through the user's
    /// login shell: tools installed with Homebrew, npm, mise or nvm are found as in Terminal.
    static func shell(_ command: String, timeout: TimeInterval = 60) async -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh")
        process.arguments = ["-ilc", command]
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit(); timer.cancel()
                done.resume(returning: (process.terminationStatus, output))
            }
        }
    }
}

struct AgentSettingsView: View {
    @State private var states: [AgentClient: String] = [:]
    @State private var copied: AgentClient?
    @State private var installed: Set<AgentClient> = []
    @State private var checked = false
    var body: some View {
        if let connector = AgentClient.connector {
            Text("Let Claude Code or Codex find moments, cut clips, write hooks and captions, and export for you. They work on your files on this Mac, and a project open here updates as they edit it.")
                .font(.system(size: 12)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(AgentClient.allCases) { client in row(client, connector) }
            Text("Then ask, for example: “Find the best moments in my latest stream and make five shorts.” Restart the agent's session after connecting.")
                .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                .task {
                    await withTaskGroup(of: AgentClient?.self) { group in
                        for client in AgentClient.allCases { group.addTask { await client.isInstalled() ? client : nil } }
                        for await client in group { if let client { installed.insert(client) } }
                    }
                    checked = true
                }
        } else {
            Text("The agent connector isn't in this build. Use a packaged Cutline (scripts/build-app.sh) to connect Claude Code or Codex.")
                .font(.system(size: 11)).foregroundStyle(Studio.muted).accessibilityIdentifier("agents.unavailable")
        }
    }
    private func row(_ client: AgentClient, _ connector: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(client.name).font(.system(size: 12, weight: .medium))
                Spacer()
                if let state = states[client] { Text(state).font(.system(size: 11)).foregroundStyle(state == "Connected" ? Studio.success : Studio.warning).lineLimit(2) }
                Button(copied == client ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(client.command(connector), forType: .string)
                    copied = client
                }.accessibilityIdentifier("agents.copy.\(client.rawValue)")
                // Always present, so finding the agent never moves the buttons under the pointer.
                Button("Connect") {
                    states[client] = "Connecting…"
                    Task {
                        do { try await client.connect(connector); states[client] = "Connected" }
                        catch { states[client] = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(!installed.contains(client))
                    .help(installed.contains(client) ? "Add Cutline to \(client.name)" : checked ? "\(client.name) isn’t installed on this Mac. Copy the command to run it later." : "Looking for \(client.name)…")
                    .accessibilityIdentifier("agents.connect.\(client.rawValue)")
            }
            Text(client.command(connector)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled).accessibilityIdentifier("agents.command.\(client.rawValue)")
        }
    }
}
