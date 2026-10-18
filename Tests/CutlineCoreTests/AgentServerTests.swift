import XCTest
import AVFoundation
@testable import CutlineCore

final class AgentServerTests: XCTestCase {
    private var root: URL!
    private let sent = SentMessages()

    override func setUpWithError() throws { root = try Fixtures.temporary() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func server(handoff: Double = 120) -> AgentServer {
        let box = OpenedBox()
        let tools = AgentTools(support: root.appendingPathComponent("Support"), exportRoot: root.appendingPathComponent("Exports"), appVersion: "test", handoffSeconds: handoff) { box.add($0) }
        openedBox = box
        return AgentServer(tools: tools) { [sent] in sent.append($0) }
    }
    private var openedBox = OpenedBox()

    private struct Reply { var isError: Bool; var text: String; var images: [Data]; var json: JSON? }
    private func call(_ server: AgentServer, _ name: String, _ arguments: JSON = [:]) async -> Reply {
        let response = await server.respond(id: 1, method: "tools/call", params: ["name": .string(name), "arguments": arguments])
        let result = response["result"]
        let content = result?["content"]?.array ?? []
        let text = content.first?["text"]?.string ?? response["error"]?["message"]?.string ?? ""
        let images = content.dropFirst().compactMap { $0["data"]?.string.flatMap { Data(base64Encoded: $0) } }
        return Reply(isError: result?["isError"]?.bool ?? true, text: text, images: images, json: try? JSON.parse(Data(text.utf8)))
    }
    private func project(_ name: String = "Edit") -> String { root.appendingPathComponent("\(name).cutline").path }

    // MARK: Protocol

    func testHandshakeNegotiatesVersionAndDescribesEveryTool() async throws {
        let agent = server()
        let hello = await agent.respond(id: 1, method: "initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:]])
        XCTAssertEqual(hello["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(hello["result"]?["serverInfo"]?["name"], "cutline")
        XCTAssertNotNil(hello["result"]?["capabilities"]?["tools"])
        let future = await agent.respond(id: 2, method: "initialize", params: ["protocolVersion": "2099-01-01"])
        XCTAssertEqual(future["result"]?["protocolVersion"]?.string, AgentServer.protocolVersions[0])
        let list = await agent.respond(id: 3, method: "tools/list", params: [:])
        let tools = try XCTUnwrap(list["result"]?["tools"]?.array)
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.string }), ["get_setup", "inspect_video", "view_frame", "find_moments", "export_shorts", "create_project", "read_project", "edit_project", "transcribe", "export_video", "open_in_cutline", "set_branding", "wait_for_job", "cancel_job"])
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"])
            XCTAssertEqual(schema["type"], "object")
            let properties = Set(schema["properties"]?.object?.keys.map { $0 } ?? [])
            for required in schema["required"]?.array?.compactMap(\.string) ?? [] { XCTAssertTrue(properties.contains(required), "\(tool["name"]!.text) requires undeclared \(required)") }
            XCTAssertFalse(tool["description"]?.string?.isEmpty ?? true)
        }
    }

    func testTransportRepliesToRequestsOnlyAndReportsBadInput() async throws {
        let agent = server()
        agent.receive(Data("{not json".utf8))
        agent.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        agent.receive(Data(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#.utf8))
        agent.receive(Data(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#.utf8))
        agent.receive(Data(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#.utf8))
        await agent.finishPending()
        let messages = sent.all
        XCTAssertEqual(messages.count, 4, "the notification gets no reply")
        XCTAssertTrue(messages.contains { $0["error"]?["code"] == -32700 && $0["id"] == .null })
        XCTAssertTrue(messages.contains { $0["id"] == "a" && $0["result"] == [:] })
        XCTAssertTrue(messages.contains { $0["id"] == 7 && $0["error"]?["code"] == -32601 })
        XCTAssertTrue(messages.contains { $0["id"] == 8 && $0["error"]?["code"] == -32602 })
        // Each message is one line, as the stdio transport requires.
        for message in messages { XCTAssertFalse(message.encoded().contains(0x0A)) }
    }

    func testProgressNotificationsStrictlyIncrease() {
        let progress = ProgressSender(token: "t", send: { [sent] in sent.append($0) })
        progress.report(0.1, "a"); progress.report(0.1, "a"); progress.report(0.05, "b"); progress.report(0.1, "c"); progress.report(0.5, "d")
        let values = sent.all.compactMap { $0["params"]?["progress"]?.number }
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values, values.sorted()); XCTAssertEqual(Set(values).count, values.count)
        ProgressSender(token: nil, send: { [sent] in sent.append($0) }).report(0.9, "silent")
        XCTAssertEqual(sent.all.count, 3)
    }

    // MARK: Projects

    func testCreateEditAndReadAProject() async throws {
        let agent = server()
        let created = await call(agent, "create_project", ["path": .string(project()), "videos": [.string(Fixtures.url("gameplay.mp4").path)], "format": "youtube"])
        XCTAssertFalse(created.isError, created.text)
        XCTAssertEqual(created.json?["videos"]?.array?.count, 1)
        XCTAssertEqual(created.json?["clips"]?.array?.count, 0)
        let edited = await call(agent, "edit_project", ["path": .string(project()), "operations": [
            ["op": "add_clip", "video": 1, "start": 0, "end": 4],
            ["op": "add_clip", "video": .string(Fixtures.url("facecam.mp4").path), "start": 0, "end": 2, "position": 1],
            ["op": "trim_clip", "clip": 1, "end": 1.5],
            ["op": "split", "time": 3],
            ["op": "set_volume", "clip": 2, "volume": 0.5],
            ["op": "move_clip", "clip": 3, "position": 1],
            ["op": "add_captions", "captions": [["start": 0, "end": 1, "text": "Watch this"]]],
            ["op": "set_quality", "resolution": 720, "fps": 30],
            ["op": "rename", "name": "Montage"]
        ]])
        XCTAssertFalse(edited.isError, edited.text)
        XCTAssertEqual(edited.json?["changes"]?.array?.count, 9)
        let read = await call(agent, "read_project", ["path": .string(project())])
        let clips = try XCTUnwrap(read.json?["clips"]?.array)
        XCTAssertEqual(clips.count, 3)
        // facecam 0–1.5, gameplay 0–1.5 | 1.5–4 after the split at 3 s, then the last part moved first.
        XCTAssertEqual(clips.map { $0["video"]?.number }, [1, 2, 1])
        XCTAssertEqual(clips.map { $0["source_start"]?.number }, [1.5, 0, 0])
        XCTAssertEqual(clips[2]["volume"]?.number, 0.5)
        XCTAssertEqual(read.json?["name"], "Montage")
        XCTAssertEqual(read.json?["length"]?.number, 5.5)
        XCTAssertEqual(read.json?["captions"]?.array?.first?["text"], "Watch this")
        XCTAssertEqual(read.json?["export_ready"], true)
        let saved = try EditProject.read(from: URL(fileURLWithPath: project()))
        XCTAssertEqual(saved.media.count, 2); XCTAssertEqual(saved.options.resolution, 720)
    }

    func testSimultaneousEditsToOneProjectAreAllKept() async throws {
        let agent = server()
        _ = await call(agent, "create_project", ["path": .string(project()), "videos": [.string(Fixtures.url("gameplay.mp4").path)], "format": "youtube"])
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { _ = await self.call(agent, "edit_project", ["path": .string(self.project()), "operations": [["op": "add_clip", "video": 1, "start": .number(Double(index) * 0.5), "end": .number(Double(index) * 0.5 + 0.5)]]]) }
            }
        }
        XCTAssertEqual(try EditProject.read(from: URL(fileURLWithPath: project())).clips.count, 8)
    }
    func testAnInvalidChangeLeavesTheProjectUntouched() async throws {
        let agent = server()
        _ = await call(agent, "create_project", ["path": .string(project()), "videos": [.string(Fixtures.url("gameplay.mp4").path)], "add_whole_videos": true])
        let before = try Data(contentsOf: URL(fileURLWithPath: project()))
        let failed = await call(agent, "edit_project", ["path": .string(project()), "operations": [["op": "set_hook", "text": "Fine"], ["op": "trim_clip", "clip": 1, "start": 10]]])
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("Change 2 (trim_clip)"), failed.text)
        XCTAssertTrue(failed.text.contains("Nothing was changed"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: project())), before)
        let clamped = await call(agent, "edit_project", ["path": .string(project()), "operations": [["op": "trim_clip", "clip": 1, "start": 1, "end": 99]]])
        XCTAssertTrue(clamped.text.contains("0:01–0:05"), clamped.text)
        let unknown = await call(agent, "edit_project", ["path": .string(project()), "operations": [["op": "explode"]]])
        XCTAssertTrue(unknown.isError); XCTAssertTrue(unknown.text.contains("add_clip"))
        let missing = await call(agent, "edit_project", ["path": .string(project()), "operations": [["op": "remove_clip", "clip": 4]]])
        XCTAssertTrue(missing.text.contains("1 clip"), missing.text)
        let exists = await call(agent, "create_project", ["path": .string(project())])
        XCTAssertTrue(exists.isError); XCTAssertTrue(exists.text.contains("already exists"))
    }

    func testShortExportExplainsEachMissingStepThenRenders() async throws {
        let agent = server()
        _ = await call(agent, "create_project", ["path": .string(project()), "videos": [.string(Fixtures.url("gameplay.mp4").path)], "add_whole_videos": true])
        var reply = await call(agent, "export_video", ["path": .string(project())])
        XCTAssertTrue(reply.isError); XCTAssertTrue(reply.text.contains("hook"), reply.text)
        _ = await call(agent, "edit_project", ["path": .string(project()), "operations": [
            ["op": "set_hook", "text": "Watch the flank"],
            ["op": "set_layout", "facecam": ["x": 0, "y": 0.7, "width": 0.3, "height": 0.3], "gameplay": ["x": 0.1, "y": 0, "width": 0.8, "height": 1]],
            ["op": "set_quality", "resolution": 720]
        ]])
        reply = await call(agent, "export_video", ["path": .string(project())])
        XCTAssertTrue(reply.isError); XCTAssertTrue(reply.text.contains("set_branding"), reply.text)
        let bad = await call(agent, "set_branding", ["kick": "two words"])
        XCTAssertTrue(bad.isError, "invalid usernames are refused")
        let named = await call(agent, "set_branding", ["kick": "https://kick.com/creator", "twitch": "@creator_tv", "badge": "twitch", "x": 0.5, "y": 0.9, "size": 1.5])
        XCTAssertFalse(named.isError, named.text)
        let setup = await call(agent, "get_setup")
        XCTAssertEqual(setup.json?["branding"]?["kick"], "creator")
        XCTAssertEqual(setup.json?["branding"]?["shows"], "@creator_tv")
        XCTAssertEqual(setup.json?["branding"]?["placement"]?["size"], 1.5)
        XCTAssertEqual(try CreatorProfileStore.load(from: root.appendingPathComponent("Support")).placement, BadgePlacement(x: 0.5, y: 0.9, size: 1.5))
        reply = await call(agent, "export_video", ["path": .string(project())])
        XCTAssertFalse(reply.isError, reply.text)
        let output = URL(fileURLWithPath: try XCTUnwrap(reply.json?["output"]?.string))
        XCTAssertEqual(output.deletingLastPathComponent().lastPathComponent, "Exports")
        let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280))
        // A second export never replaces the first without permission.
        let again = await call(agent, "export_video", ["path": .string(project()), "output_path": .string(output.path)])
        XCTAssertTrue(again.isError); XCTAssertTrue(again.text.contains("overwrite"))
        let source = await call(agent, "export_video", ["path": .string(project()), "output_path": .string(Fixtures.url("gameplay.mp4").path), "overwrite": true])
        XCTAssertTrue(source.isError, "source media is never overwritten")
    }

    func testViewFrameShowsTheRecordingAndTheRender() async throws {
        let agent = server()
        let frames = await call(agent, "view_frame", ["video_path": .string(Fixtures.url("autoclip.mp4").path), "times": [0, 2.5], "size": 320])
        XCTAssertFalse(frames.isError, frames.text)
        XCTAssertEqual(frames.images.count, 2)
        for image in frames.images { XCTAssertEqual(Array(image.prefix(2)), [0xFF, 0xD8], "JPEG") }
        _ = await call(agent, "create_project", ["path": .string(project()), "videos": [.string(Fixtures.url("gameplay.mp4").path)], "add_whole_videos": true])
        let render = await call(agent, "view_frame", ["project_path": .string(project()), "time": 1])
        XCTAssertFalse(render.isError, render.text)
        XCTAssertEqual(render.images.count, 1)
        XCTAssertTrue(render.text.contains("layout hasn’t been set"), render.text)
        let neither = await call(agent, "view_frame", [:])
        XCTAssertTrue(neither.isError)
    }

    // MARK: Streams

    func testFindMomentsThenExportShorts() async throws {
        let agent = server()
        let found = await call(agent, "find_moments", ["video_path": .string(Fixtures.url("autoclip.mp4").path), "audio_track": 1, "sensitivity": 0.8])
        XCTAssertFalse(found.isError, found.text)
        XCTAssertNotNil(found.json?["moments"]?.array)
        XCTAssertEqual(found.json?["listened_to_track"], 1)
        let badTrack = await call(agent, "find_moments", ["video_path": .string(Fixtures.url("autoclip.mp4").path), "audio_track": 5])
        XCTAssertTrue(badTrack.isError); XCTAssertTrue(badTrack.text.contains("2 audio tracks"), badTrack.text)

        let moment: JSON = ["start": 1, "end": 4, "hook": "No way"]
        var reply = await call(agent, "export_shorts", ["video_path": .string(Fixtures.url("autoclip.mp4").path), "moments": [moment]])
        XCTAssertTrue(reply.isError); XCTAssertTrue(reply.text.contains("facecam"), reply.text)
        let layout: [String: JSON] = ["video_path": .string(Fixtures.url("autoclip.mp4").path), "moments": [moment], "quality": 720,
                                      "facecam": ["x": 0, "y": 0.75, "width": 0.25, "height": 0.25], "gameplay": ["x": 0, "y": 0, "width": 1, "height": 1],
                                      "output_folder": .string(root.appendingPathComponent("Shorts").path)]
        reply = await call(agent, "export_shorts", .object(layout))
        XCTAssertTrue(reply.isError); XCTAssertTrue(reply.text.contains("Kick username"), reply.text)
        _ = await call(agent, "set_branding", ["kick": "creator"])
        reply = await call(agent, "export_shorts", .object(layout))
        XCTAssertFalse(reply.isError, reply.text)
        let shorts = try XCTUnwrap(reply.json?["shorts"]?.array?.compactMap(\.string))
        XCTAssertEqual(shorts.count, 1)
        XCTAssertTrue(shorts[0].hasSuffix("01 - No way.mp4"), shorts[0])
        let folder = try XCTUnwrap(reply.json?["folder"]?.string)
        XCTAssertEqual(URL(fileURLWithPath: folder).lastPathComponent, "autoclip shorts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: folder).appendingPathComponent("Editable projects/01 - No way.cutline").path))
        var badHook = layout; badHook["moments"] = [["start": 1, "end": 4, "hook": ""]]
        let empty = await call(agent, "export_shorts", .object(badHook))
        XCTAssertTrue(empty.isError); XCTAssertTrue(empty.text.contains("hook"))
    }

    // MARK: Jobs and the app

    func testLongJobsHandOffAJobIdAndFinishThroughWait() async throws {
        let agent = server(handoff: 0)
        let created = await call(agent, "create_project", ["path": .string(project()), "videos": [.string(Fixtures.url("gameplay.mp4").path)], "format": "youtube", "add_whole_videos": true])
        let id = try XCTUnwrap(created.json?["job_id"]?.string, created.text)
        var reply = await call(agent, "wait_for_job", ["job_id": .string(id)])
        for _ in 0..<200 where reply.json?["status"] == "running" {
            try await Task.sleep(nanoseconds: 50_000_000)
            reply = await call(agent, "wait_for_job", ["job_id": .string(id)])
        }
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(reply.json?["clips"]?.array?.count, 1)
        let started = await call(agent, "export_video", ["path": .string(project())])
        let exportID = try XCTUnwrap(started.json?["job_id"]?.string)
        let cancelled = await call(agent, "cancel_job", ["job_id": .string(exportID)])
        XCTAssertFalse(cancelled.isError)
        let missing = await call(agent, "wait_for_job", ["job_id": "job-none"])
        XCTAssertTrue(missing.isError)
    }

    func testOpenInCutlineHandsTheProjectToTheApp() async throws {
        let agent = server()
        let refused = await call(agent, "open_in_cutline", ["path": .string(project())])
        XCTAssertTrue(refused.isError)
        _ = await call(agent, "create_project", ["path": .string(project())])
        let opened = await call(agent, "open_in_cutline", ["path": .string(project())])
        XCTAssertFalse(opened.isError, opened.text)
        XCTAssertEqual(openedBox.urls.map(\.path), [URL(fileURLWithPath: project()).standardizedFileURL.path])
    }

    func testPathsAcceptHomeRelativeAndAbsoluteForms() {
        XCTAssertEqual(AgentPaths.url("~/Movies/a.mp4").path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/a.mp4").path)
        XCTAssertEqual(AgentPaths.url("/tmp/../tmp/b.mp4").path, "/tmp/b.mp4")
        XCTAssertEqual(AgentPaths.url("c.mp4").path, URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("c.mp4").standardizedFileURL.path)
    }
}

private final class SentMessages: @unchecked Sendable {
    private let lock = NSLock(); private var messages: [JSON] = []
    func append(_ message: JSON) { lock.withLock { messages.append(message) } }
    var all: [JSON] { lock.withLock { messages } }
}
private final class OpenedBox: @unchecked Sendable {
    private let lock = NSLock(); private var opened: [URL] = []
    func add(_ url: URL) { lock.withLock { opened.append(url) } }
    var urls: [URL] { lock.withLock { opened } }
}
