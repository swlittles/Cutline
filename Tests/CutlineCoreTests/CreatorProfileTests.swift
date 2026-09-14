import XCTest
import CoreImage
@testable import CutlineCore

final class CreatorProfileTests: XCTestCase {
    func testFreshInstallAndGameProfilesHaveNoIdentity() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try CreatorProfileStore.load(from: root), ShortBranding())
        for game in ClipGame.allCases { XCTAssertTrue(AutoClipSettings.preset(game).aliases.isEmpty) }
        XCTAssertThrowsError(try ShortBranding().validate())
    }
    func testLocalProfileRoundTripReplacementAndPermissions() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        for profile in [ShortBranding(text: "example.test/first", logo: .kick), ShortBranding(text: "A different creator"), ShortBranding()] {
            try CreatorProfileStore.save(profile, to: root)
            XCTAssertEqual(try CreatorProfileStore.load(from: root), profile)
            let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("creator-profile.json").path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["creator-profile.json"])
    }
    func testInvalidProfileCannotOverwriteSavedValue() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = ShortBranding(text: "example.test/channel")
        try CreatorProfileStore.save(original, to: root)
        for text in [String(repeating: "a", count: 81), "line\nbreak", "tab\tname"] {
            XCTAssertThrowsError(try CreatorProfileStore.save(ShortBranding(text: text), to: root))
            XCTAssertEqual(try CreatorProfileStore.load(from: root), original)
        }
    }
    func testCorruptLocalProfileReportsFailure() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("broken".utf8).write(to: root.appendingPathComponent("creator-profile.json"))
        XCTAssertThrowsError(try CreatorProfileStore.load(from: root))
    }
    func testMissingBrandingBlocksShortExportWithoutOutput() async throws {
        let p = OutputWorkflowTests().shortProject()
        let render = try await CompositionEngine.build(p)
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("short.mp4")
        do { try await CompositionEngine.export(render, to: url); XCTFail("Missing brand must block export") }
        catch { XCTAssertTrue(error.localizedDescription.contains("branding")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testBrandCacheSeparatesCreatorsAndDoesNotPersistProfileInProject() throws {
        let compositor = CutlineVideoCompositor(), size = CGSize(width: 1080, height: 38)
        func pixels(_ profile: ShortBranding) -> Data {
            let image = compositor.shortBrand(size: size, branding: profile)
            var bytes = [UInt8](repeating: 0, count: 1080*38*4)
            CIContext().render(image, toBitmap: &bytes, rowBytes: 1080*4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return Data(bytes)
        }
        let a = ShortBranding(text: "example.test/first"), b = ShortBranding(text: "example.test/second", logo: .kick)
        XCTAssertNotEqual(pixels(a), pixels(b)); XCTAssertEqual(pixels(a), pixels(a))
        let document = String(decoding: try JSONEncoder().encode(OutputWorkflowTests().shortProject()), as: UTF8.self)
        XCTAssertFalse(document.contains(a.text)); XCTAssertFalse(document.contains("branding"))
    }
}
