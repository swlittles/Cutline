import XCTest
@testable import CutlineCore
final class AppEnvironmentTests: XCTestCase {
    func testProductionIdentityEnablesReleaseEnvironment() {
        let env = AppEnvironment(bundleIdentifier: "studio.cutline.editor")
        XCTAssertFalse(env.isDevelopment); XCTAssertEqual(env.name, "Cutline")
        XCTAssertEqual(env.credentialService, "studio.cutline.openrouter")
    }
    func testUnknownAndTestBundlesAlwaysUseDevelopment() {
        for identifier in [nil, "", "studio.cutline.editor.dev", "studio.cutline.editor.tests", "other"] {
            let env = AppEnvironment(bundleIdentifier: identifier)
            XCTAssertTrue(env.isDevelopment); XCTAssertEqual(env.name, "Cutline Dev")
        }
    }
    func testDevelopmentCannotShareReleaseStorageOrCredentials() {
        let dev = AppEnvironment(bundleIdentifier: nil), release = AppEnvironment(bundleIdentifier: "studio.cutline.editor")
        let root = URL(fileURLWithPath: "/tmp/support")
        XCTAssertNotEqual(dev.bundleIdentifier, release.bundleIdentifier)
        XCTAssertNotEqual(dev.credentialService, release.credentialService)
        XCTAssertEqual(dev.supportURL(root: root).lastPathComponent, "Cutline Dev")
        XCTAssertEqual(release.supportURL(root: root).lastPathComponent, "Cutline")
    }
    func testVersionLabelNamesTheBuild() {
        XCTAssertEqual(AppEnvironment(bundleIdentifier: "studio.cutline.editor").versionLabel("0.5.1"), "Cutline 0.5.1")
        XCTAssertEqual(AppEnvironment(bundleIdentifier: "studio.cutline.editor.dev").versionLabel("0.5.1"), "Cutline Dev 0.5.1")
        XCTAssertEqual(AppEnvironment(bundleIdentifier: nil).versionLabel(nil), "Cutline Dev (local build)")
        XCTAssertEqual(AppEnvironment(bundleIdentifier: nil).versionLabel(""), "Cutline Dev (local build)")
    }
}
