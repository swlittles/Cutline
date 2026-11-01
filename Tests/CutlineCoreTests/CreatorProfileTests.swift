import XCTest
import CoreImage
@testable import CutlineCore

final class CreatorProfileTests: XCTestCase {
    func testFreshInstallHasNoIdentity() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try CreatorProfileStore.load(from: root), ShortBranding())
        XCTAssertThrowsError(try ShortBranding().validate())
    }
    func testLocalProfileRoundTripReplacementAndPermissions() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        for profile in [ShortBranding(kick: "first"), ShortBranding(kick: "first", twitch: "second_name", badge: .twitch, placement: BadgePlacement(x: 0.2, y: 0.8, size: 1.6)), ShortBranding()] {
            try CreatorProfileStore.save(profile, to: root)
            XCTAssertEqual(try CreatorProfileStore.load(from: root), profile)
            let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("creator-profile.json").path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["creator-profile.json"])
    }
    func testInvalidProfileCannotOverwriteSavedValue() throws {
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = ShortBranding(kick: "channel")
        try CreatorProfileStore.save(original, to: root)
        for text in [String(repeating: "a", count: 41), "line\nbreak", "tab\tname", "two words", "semi;colon"] {
            XCTAssertThrowsError(try CreatorProfileStore.save(ShortBranding(kick: text), to: root))
            XCTAssertThrowsError(try CreatorProfileStore.save(ShortBranding(twitch: text), to: root))
            XCTAssertEqual(try CreatorProfileStore.load(from: root), original)
        }
        for placement in [BadgePlacement(x: 1.2), BadgePlacement(y: -0.1), BadgePlacement(size: 3), BadgePlacement(size: .nan)] {
            XCTAssertThrowsError(try CreatorProfileStore.save(ShortBranding(kick: "channel", placement: placement), to: root))
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
        catch { XCTAssertTrue(error.localizedDescription.contains("Kick username"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testBadgeCacheSeparatesCreatorsAndDoesNotPersistProfileInProject() throws {
        let compositor = CutlineVideoCompositor(), canvas = CGSize(width: 1080, height: 1920)
        func pixels(_ profile: ShortBranding) throws -> Data {
            let image = try XCTUnwrap(compositor.brandBadge(profile, canvas: canvas))
            var bytes = [UInt8](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
            CIContext().render(image, toBitmap: &bytes, rowBytes: Int(image.extent.width) * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return Data(bytes)
        }
        let a = ShortBranding(kick: "first"), b = ShortBranding(kick: "first", twitch: "second", badge: .twitch)
        XCTAssertNotEqual(try pixels(a), try pixels(b)); XCTAssertEqual(try pixels(a), try pixels(a))
        XCTAssertNil(compositor.brandBadge(ShortBranding(twitch: "only", badge: .kick), canvas: canvas), "no badge without the chosen platform's username")
        let document = String(decoding: try JSONEncoder().encode(OutputWorkflowTests().shortProject()), as: UTF8.self)
        XCTAssertFalse(document.contains("first")); XCTAssertFalse(document.contains("branding")); XCTAssertFalse(document.contains("badge"))
    }
    func testUsernamesAcceptHandlesAndPastedAddresses() {
        for text in ["blankmantv", "@blankmantv", " kick.com/blankmantv ", "https://kick.com/blankmantv/", "https://www.twitch.tv/blankmantv"] {
            XCTAssertEqual(ShortBranding.username(text), "blankmantv", text)
        }
        let branding = ShortBranding(kick: "https://kick.com/blankmantv", twitch: "@blankmanstv")
        XCTAssertEqual(branding.displayText, "@blankmantv")
        var twitch = branding; twitch.badge = .twitch
        XCTAssertEqual(twitch.displayText, "@blankmanstv")
        XCTAssertEqual(ShortBranding(twitch: "x").displayText, "", "the chosen badge needs its own username")
    }
    func testProfilesFromBeforeBadgesMigrate() throws {
        func migrate(_ json: String) throws -> ShortBranding { try JSONDecoder().decode(ShortBranding.self, from: Data(json.utf8)) }
        let kick = try migrate(#"{"text":"Kick.com/blankmantv","logo":"kick"}"#)
        XCTAssertEqual(kick.kick, "blankmantv"); XCTAssertEqual(kick.badge, .kick); XCTAssertEqual(kick.placement, BadgePlacement())
        let twitch = try migrate(#"{"text":"twitch.tv/blankmanstv","logo":"none"}"#)
        XCTAssertEqual(twitch.twitch, "blankmanstv"); XCTAssertEqual(twitch.badge, .twitch); XCTAssertEqual(twitch.kick, "")
        let words = try migrate(#"{"text":"A different creator","logo":"none"}"#)
        XCTAssertNoThrow(try words.validate()); XCTAssertEqual(words.kick, "Adifferentcreator")
        XCTAssertEqual(try migrate(#"{"text":"","logo":"none"}"#), ShortBranding())
    }
    func testBadgePlacementStaysInsideTheFrame() {
        let canvas = CGSize(width: 1080, height: 1920), badge = CGSize(width: 420, height: 76)
        XCTAssertEqual(BadgePlacement().rect(badge: badge, canvas: canvas), CGRect(x: 330, y: 557, width: 420, height: 76))
        XCTAssertEqual(BadgePlacement(x: 0, y: 0).rect(badge: badge, canvas: canvas).origin, .zero)
        XCTAssertEqual(BadgePlacement(x: 1, y: 1).rect(badge: badge, canvas: canvas).maxX, 1080)
        XCTAssertEqual(BadgePlacement(x: 1, y: 1).rect(badge: badge, canvas: canvas).maxY, 1920)
    }
    func testLogosFollowTheirArtwork() {
        XCTAssertEqual(BrandBadge.logo(.kick).boundingBoxOfPath.integral, CGRect(x: 1, y: 0, width: 22, height: 24))
        let twitch = BrandBadge.logo(.twitch)
        XCTAssertEqual(twitch.boundingBoxOfPath.integral, CGRect(x: 1, y: 0, width: 22, height: 24))
        // The eyes are solid, the space around them is cut out, and outside the bubble is empty.
        XCTAssertTrue(twitch.contains(CGPoint(x: 12.4, y: 7), using: .winding))
        XCTAssertTrue(twitch.contains(CGPoint(x: 17.1, y: 7), using: .winding))
        XCTAssertFalse(twitch.contains(CGPoint(x: 15, y: 7), using: .winding))
        XCTAssertTrue(twitch.contains(CGPoint(x: 3, y: 12), using: .winding))
        XCTAssertFalse(twitch.contains(CGPoint(x: 23, y: 23), using: .winding))
    }
}
