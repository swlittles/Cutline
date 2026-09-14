import XCTest
import CutlineCore
@testable import Cutline

extension EditorStoreTests {
    func testCreatorProfileReloadsLocallyWithoutDirtyingProject() throws {
        seed(); let document = store.project
        XCTAssertEqual(store.creatorProfile, ShortBranding())
        let profile = ShortBranding(text: "example.test/channel", logo: .kick)
        try store.saveCreatorProfile(profile)
        XCTAssertEqual(store.project, document); XCTAssertFalse(store.dirty); XCTAssertTrue(store.undoStack.isEmpty)
        let reopened = EditorStore(); defer { reopened.resetJobs() }
        XCTAssertEqual(reopened.creatorProfile, profile)
        XCTAssertEqual(try CreatorProfileStore.load(from: root), profile)
    }
    func testShortExportPreflightRequiresLocalBrandingButYouTubeDoesNot() throws {
        seed(); store.project.shortHook = "Watch this play"
        store.project.media[0].shortFraming = ShortFraming(); store.project.media[0].shortFraming?.confirmed = true
        XCTAssertThrowsError(try store.validateExport(store.project))
        try store.saveCreatorProfile(ShortBranding(text: "example.test/channel"))
        XCTAssertNoThrow(try store.validateExport(store.project))
        try store.saveCreatorProfile(ShortBranding()); XCTAssertThrowsError(try store.validateExport(store.project))
        store.project.selectWorkflow(.youtubeVideo); XCTAssertNoThrow(try store.validateExport(store.project))
    }
}
