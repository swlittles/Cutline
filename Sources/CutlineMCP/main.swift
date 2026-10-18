import Foundation
import CutlineCore

// Cutline's agent connector: a Model Context Protocol server on stdin/stdout that Claude Code,
// Codex and other agents launch. stdout carries protocol messages only; notes go to stderr.

let arguments = CommandLine.arguments.dropFirst()
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
if arguments.contains("--version") { print("cutline-mcp \(AgentTools.bundleVersion)"); exit(0) }
if arguments.contains("--help") || isatty(STDIN_FILENO) == 1 {
    let help = """
    This is Cutline's connector for AI agents. Agents start it themselves; you don't run it directly.

    Claude Code:  claude mcp add --scope user cutline -- '\(executable)'
    Codex:        codex mcp add cutline -- '\(executable)'

    Then ask the agent things like "find the best moments in ~/Movies/stream.mp4 and make shorts".
    Cutline → Settings → AI Agents has these steps too.

    """
    FileHandle.standardError.write(Data(help.utf8))
    exit(arguments.contains("--help") ? 0 : 64)
}

signal(SIGPIPE, SIG_IGN)
let output = FileHandle.standardOutput
let outputLock = NSLock()
let server = AgentServer { message in
    var line = message.encoded(); line.append(0x0A)
    outputLock.lock(); defer { outputLock.unlock() }
    try? output.write(contentsOf: line)
}
// The client closing stdin ends the session.
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    server.receive(Data(line.utf8))
}
let done = DispatchSemaphore(value: 0)
Task { await server.finishPending(); done.signal() }
done.wait()
exit(0)
