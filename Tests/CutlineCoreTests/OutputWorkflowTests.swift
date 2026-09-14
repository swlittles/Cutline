import XCTest
import AVFoundation
import CoreImage
@testable import CutlineCore

final class OutputWorkflowTests: XCTestCase {
    func shortProject() -> EditProject {
        var p = Fixtures.project(); p.selectWorkflow(.mobileShort); p.shortHook = "Watch this play"
        p.media[0].shortFraming = ShortFraming(); p.media[0].shortFraming?.confirmed = true
        p.clips[0].sourceOut = 0.5
        return p
    }
    func testNewProjectsAreMobileAndWorkflowOverridesStaleCanvas() {
        var p = EditProject(); XCTAssertEqual(p.workflow, .mobileShort); XCTAssertEqual(p.outputFormat, .portrait)
        p.options.fps = 60; p.selectWorkflow(.mobileShort); XCTAssertEqual(p.options.fps, 60)
        p.format = .landscape; XCTAssertEqual(p.outputFormat, .portrait)
        p.selectWorkflow(.youtubeVideo); XCTAssertEqual(p.outputFormat, .landscape)
        p.format = .square; XCTAssertEqual(p.outputFormat, .landscape)
    }
    func testOlderProjectRetainsFramingAndRequiresExplicitClassification() throws {
        var p = Fixtures.project(); p.workflow = nil; p.format = .landscape
        let decoded = try JSONDecoder().decode(EditProject.self, from: JSONEncoder().encode(p))
        XCTAssertNil(decoded.workflow); XCTAssertEqual(decoded.outputFormat, .landscape)
        XCTAssertThrowsError(try decoded.validateForExport())
        var converted = decoded; converted.selectWorkflow(.youtubeVideo); XCTAssertNoThrow(try converted.validateForExport())
        XCTAssertEqual(converted.clips, p.clips)
    }
    func testShortFramingHooksAndIntentRoundTrip() throws {
        var p = shortProject(); p.autoClipHooks = ["one": "A second hook"]; p.clips[0].shortHook = "Custom hook"
        let decoded = try JSONDecoder().decode(EditProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p); XCTAssertEqual(decoded.hook(for: decoded.clips[0]), "Custom hook")
        XCTAssertNoThrow(try decoded.validateForExport())
    }
    func testHookRequiredForEveryClipAndInvalidHooksRejected() {
        for hook in ["", "   ", "\n", String(repeating: "a", count: 81), "Line\nbreak"] {
            var p = shortProject(); p.shortHook = hook; XCTAssertThrowsError(try p.validateForExport())
            XCTAssertNoThrow(try p.validate(), "Unfinished drafts must remain saveable")
        }
        var p = shortProject(); var second = p.clips[0]; second.id = UUID(); second.shortHook = ""; p.clips.append(second)
        XCTAssertThrowsError(try p.validateForExport())
        p.clips[1].shortHook = "Another play"; XCTAssertNoThrow(try p.validateForExport())
    }
    func testEverySourceNeedsConfirmedValidCrops() {
        var p = shortProject(); p.media[0].shortFraming?.confirmed = false; XCTAssertThrowsError(try p.validateForExport())
        p.media[0].shortFraming = nil; XCTAssertThrowsError(try p.validateForExport())
        p.media[0].shortFraming = ShortFraming(); p.media[0].shortFraming?.camera.x = .nan; XCTAssertThrowsError(try p.validate())
        p = shortProject(); p.media[0].shortFraming?.gameplay.width = 2; XCTAssertThrowsError(try p.validate())
    }
    func testYouTubeExportDoesNotRequireShortHookOrFacecam() {
        let p = Fixtures.project(); XCTAssertNoThrow(try p.validateForExport()); XCTAssertEqual(p.outputFormat, .landscape)
    }
    func testGeometryTilesCanvasAtEveryExportResolution() {
        for width in [720.0,1080,2160] {
            let size = CGSize(width: width, height: width * 16/9), g = ShortGeometry(size: size)
            XCTAssertEqual(g.camera.maxY, size.height); XCTAssertEqual(g.camera.minY, g.brand.maxY)
            XCTAssertEqual(g.brand.minY, g.gameplay.maxY); XCTAssertEqual(g.gameplay.minY, 0)
            XCTAssertEqual(g.camera.height, size.height * 0.30, accuracy: 0.5)
            XCTAssertEqual(g.brand.height, size.height * 0.02, accuracy: 1)
        }
        let g = ShortGeometry(size: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(g.camera.height, 576); XCTAssertEqual(g.brand.height, 38); XCTAssertEqual(g.gameplay.height, 1306)
    }
    func testSourceCropsUseTopLeftAndPanelsHaveNoDuplicateCamera() {
        let size = CGSize(width: 1080, height: 1920), canvas = CGRect(origin: .zero, size: size)
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50)).composited(over: source)
        var framing = ShortFraming(); framing.camera = ClipScanRegion(x: 0, y: 0, width: 0.5, height: 0.5); framing.gameplay = ClipScanRegion(x: 0.5, y: 0, width: 0.5, height: 1)
        let image = CutlineVideoCompositor.shortPanels(red, framing: framing, canvas: canvas)
        XCTAssertEqual(pixel(image, x: 540, y: 1600), [255,0,0,255])
        XCTAssertEqual(pixel(image, x: 540, y: 1320), [0,0,0,255])
        XCTAssertEqual(pixel(image, x: 540, y: 600), [0,0,255,255])
        framing.containGameplay = true
        let fitted = CutlineVideoCompositor.shortPanels(red, framing: framing, canvas: canvas)
        XCTAssertEqual(pixel(fitted, x: 1, y: 1), [0,0,0,255])
    }
    func testMandatoryBrandContainsBlackStripGreenMarkAndWhiteAddress() {
        let image = CutlineVideoCompositor().shortBrand(size: CGSize(width: 1080, height: 38), branding: ShortBranding(text: "example.test/player", logo: .kick))
        XCTAssertEqual(pixel(image, x: 1, y: 20), [0,0,0,255])
        var bytes = [UInt8](repeating: 0, count: 1080 * 38 * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: 1080 * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let pixels = stride(from: 0, to: bytes.count, by: 4)
        XCTAssertGreaterThan(pixels.filter { bytes[$0+1] > 180 && bytes[$0] < 130 && bytes[$0+2] < 80 }.count, 100)
        XCTAssertGreaterThan(pixels.filter { bytes[$0] > 200 && bytes[$0+1] > 200 && bytes[$0+2] > 200 }.count, 300)
    }
    func testEngineRefusesIncompleteShortBeforeCreatingOutput() async throws {
        var p = shortProject(); p.shortHook = ""
        let render = try await CompositionEngine.build(p)
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("missing-hook.mp4")
        do { try await CompositionEngine.export(render, to: url); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("hook")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testAutomaticClipsCannotInheritYouTubeCanvas() throws {
        let p = Fixtures.project(), candidate = AutoClipCandidate(id: "one", start: 0, end: 1, score: 1, evidence: [])
        let result = try AutoClipRules.project(for: candidate, media: p.media[0])
        XCTAssertEqual(result.workflow, .mobileShort); XCTAssertEqual(result.outputFormat, .portrait)
        XCTAssertThrowsError(try result.validateForExport())
    }
    func testCalibrationChangesDoNotInvalidateScanSourceIdentity() {
        let original = Fixtures.project().media[0]; var edited = original
        edited.shortFraming = ShortFraming(); edited.shortFraming?.confirmed = true
        XCTAssertTrue(edited.sameSource(as: original)); edited.url = Fixtures.url("facecam.mp4"); XCTAssertFalse(edited.sameSource(as: original))
    }
    func testRealExportBurnsBrandAndHookEvenDuringFade() async throws {
        var p = shortProject(); p.clips[0].adjustments = ClipAdjustments(); p.clips[0].adjustments?.fadeIn = 2
        let root = try Fixtures.temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("branded.mp4")
        let render = try await CompositionEngine.build(p, branding: ShortBranding(text: "example.test/player", logo: .kick)); try await CompositionEngine.export(render, to: url)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let frame = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        XCTAssertEqual(frame.width, 720); XCTAssertEqual(frame.height, 1280)
        let image = CIImage(cgImage: frame), geometry = ShortGeometry(size: CGSize(width: 720, height: 1280))
        func colors(in rect: CGRect, matching predicate: (UInt8, UInt8, UInt8) -> Bool) -> Int {
            let rect = rect.integral
            var bytes = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
            CIContext().render(image, toBitmap: &bytes, rowBytes: Int(rect.width) * 4, bounds: rect, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return stride(from: 0, to: bytes.count, by: 4).filter { predicate(bytes[$0], bytes[$0+1], bytes[$0+2]) }.count
        }
        XCTAssertGreaterThan(colors(in: geometry.brand) { r,g,b in g > 170 && r < 150 && b < 110 }, 40, "Kick mark must survive fades")
        let hook = CGRect(x: 0, y: geometry.gameplay.maxY - 110, width: 720, height: 100)
        XCTAssertGreaterThan(colors(in: hook) { r,g,b in r > 180 && g > 150 && b < 100 }, 150, "Editable hook must be burned into the video")
    }
    private func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &value, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return value
    }
}
