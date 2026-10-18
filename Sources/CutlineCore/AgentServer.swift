import Foundation

/// A Model Context Protocol server, so Claude Code, Codex and other agents can edit videos with
/// Cutline's engine. Messages are newline-delimited JSON-RPC 2.0 over any transport: `receive`
/// takes one message and `send` writes one. Requests run concurrently, so a long export never
/// blocks a ping or a cancellation.
public final class AgentServer: @unchecked Sendable {
    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let instructions = """
    Cutline edits videos on this Mac. Everything stays local. Times are in seconds; clip, video, caption and audio-track numbers start at 1.
    Shorts from a stream: get_setup → find_moments → view_frame to check → export_shorts with a hook for each moment.
    Editing: create_project (or read_project on an existing .cutline file) → edit_project → view_frame → export_video.
    open_in_cutline shows a project in the app; while it is open there, every edit_project change appears live and the user can undo it.
    Long jobs hand back a job id after about 40 seconds; call wait_for_job until it finishes.
    Before exporting a short, the facecam/gameplay layout must be set (a saved layout from get_setup, or set_layout) and every clip needs a hook of 1–80 characters.
    Ask the user before overwriting their files or changing their usernames or badge.
    """
    let tools: AgentTools
    let send: @Sendable (JSON) -> Void
    private let lock = NSLock()
    private var running: [String: Task<Void, Never>] = [:]

    public init(tools: AgentTools = AgentTools(), send: @escaping @Sendable (JSON) -> Void) {
        self.tools = tools; self.send = send
    }

    /// Handles one message from the client. Replies arrive through `send`.
    public func receive(_ line: Data) {
        guard let message = try? JSON.parse(line) else { send(Self.error(id: .null, code: -32700, "That message isn’t valid JSON.")); return }
        guard let method = message["method"]?.string else {
            if message.object == nil { send(Self.error(id: .null, code: -32600, "Send one JSON-RPC object per line.")) }
            return
        }
        if method == "notifications/cancelled" { cancel(message["params"]?["requestId"]); return }
        // Other notifications (such as notifications/initialized) need no reply.
        guard let id = message["id"], !id.isNull else { return }
        let key = id.text, params = message["params"] ?? [:]
        lock.lock(); defer { lock.unlock() }
        running[key] = Task { [weak self] in
            guard let self else { return }
            let response = await self.respond(id: id, method: method, params: params)
            let cancelled = Task.isCancelled
            self.lock.withLock { self.running[key] = nil }
            // A cancelled request gets no reply, as the protocol asks.
            if !cancelled { self.send(response) }
        }
    }

    /// Answers one request directly; used by `receive` and by tests.
    public func respond(id: JSON, method: String, params: JSON) async -> JSON {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            return Self.result(id: id, [
                "protocolVersion": .string(Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "cutline", "title": "Cutline", "version": .string(tools.appVersion)],
                "instructions": .string(Self.instructions)
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.definitions)])
        case "tools/call":
            guard let name = params["name"]?.string, tools.has(name) else {
                return Self.error(id: id, code: -32602, "Unknown tool \(params["name"]?.string ?? "(none)"). Call tools/list for the available tools.")
            }
            let arguments = params["arguments"] ?? [:]
            guard arguments.object != nil else { return Self.error(id: id, code: -32602, "Tool arguments must be an object.") }
            let progress = ProgressSender(token: params["_meta"]?["progressToken"], send: send)
            do {
                return Self.result(id: id, try await tools.call(name, arguments: arguments, progress: { progress.report($0, $1) }).json)
            } catch {
                // Tool failures are results the agent can read and act on, not protocol errors.
                return Self.result(id: id, AgentToolResult(text: Self.describe(error), isError: true).json)
            }
        default:
            return Self.error(id: id, code: -32601, "Cutline doesn’t support \(method).")
        }
    }

    /// Waits for requests already received, so a client that closes its input still gets every reply.
    public func finishPending() async {
        while lock.withLock({ !running.isEmpty }) { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func cancel(_ id: JSON?) {
        guard let id else { return }
        lock.lock(); let task = running.removeValue(forKey: id.text); lock.unlock()
        task?.cancel()
    }
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        return error.localizedDescription
    }
    static func result(id: JSON, _ result: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }
    static func error(id: JSON, code: Int, _ message: String) -> JSON { ["jsonrpc": "2.0", "id": id, "error": ["code": JSON(code), "message": .string(message)]] }
}

/// Progress notifications must strictly increase, so stale or repeated values are dropped.
final class ProgressSender: @unchecked Sendable {
    private let token: JSON?
    private let send: @Sendable (JSON) -> Void
    private let lock = NSLock()
    private var last = -1.0
    private var lastMessage = ""
    init(token: JSON?, send: @escaping @Sendable (JSON) -> Void) { self.token = token; self.send = send }
    func report(_ fraction: Double, _ message: String) {
        guard let token, !token.isNull else { return }
        let value = (max(0, min(1, fraction.isFinite ? fraction : 0)) * 1000).rounded() / 10
        lock.lock()
        guard value > last || (value == last && message != lastMessage && value < 100) else { lock.unlock(); return }
        // Equal values with a new message nudge forward so the sequence still increases.
        let sent = value > last ? value : last + 0.01
        last = sent; lastMessage = message
        lock.unlock()
        send(["jsonrpc": "2.0", "method": "notifications/progress", "params": ["progressToken": token, "progress": JSON(sent), "total": 100, "message": .string(message)]])
    }
}
