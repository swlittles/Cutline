import XCTest
import AppKit
import CutlineCore

extension EditorUITests {
    func testSettingsOfferTheAgentConnector() throws {
        launch()
        app.typeKey(",", modifierFlags: .command)
        let claude = app.staticTexts["agents.command.claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5))
        let command = claude.value as? String ?? claude.label
        XCTAssertTrue(command.hasPrefix("claude mcp add --scope user cutline-dev -- '"), command)
        XCTAssertTrue(command.hasSuffix("/Contents/MacOS/cutline-mcp'"), command)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: String(command.split(separator: "'")[1])), "the connector ships inside the app")
        // Tests never connect: Connect would change this Mac's agent settings, so it stays off here.
        XCTAssertFalse(app.buttons["agents.connect.codex"].isEnabled)
        XCTAssertFalse(app.buttons["agents.connect.claude"].isEnabled)
        NSPasteboard.general.clearContents()
        app.buttons["agents.copy.codex"].click()
        let copied = expectation(for: NSPredicate(format: "label == %@", "Copied"), evaluatedWith: app.buttons["agents.copy.codex"])
        wait(for: [copied], timeout: 5)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.hasPrefix("codex mcp add cutline-dev -- '") == true)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); screenshot.name = "AI agents settings"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testAnAgentsEditAppearsInTheOpenProjectAndUndoes() async throws {
        launch()
        XCTAssertTrue(app.staticTexts["editor.status"].waitForExistence(timeout: 10))
        let tools = AgentTools(support: root, exportRoot: root, appVersion: "test")
        let result = try await tools.call("edit_project", arguments: ["path": .string(projectURL.path), "operations": [["op": "rename", "name": "Agent cut"], ["op": "trim_clip", "clip": 1, "end": 2]]])
        XCTAssertFalse(result.isError, result.text)
        let status = app.staticTexts["editor.status"]
        let updated = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "AI agent", "AI agent")
        await fulfillment(of: [expectation(for: updated, evaluatedWith: status)], timeout: 10)
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("s", modifierFlags: .command)
        let reverted = NSPredicate { _, _ in (try? EditProject.read(from: self.projectURL))?.clips.first?.sourceOut == 5 }
        await fulfillment(of: [expectation(for: reverted, evaluatedWith: nil)], timeout: 10)
    }
}
