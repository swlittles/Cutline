import XCTest
import CutlineCore
@testable import Cutline

extension EditorStoreTests {
    func testCreatorProfileReloadsLocallyWithoutDirtyingProject() throws {
        seed(); let document = store.project
        XCTAssertEqual(store.creatorProfile, ShortBranding())
        let profile = ShortBranding(kick: "channel", twitch: "other", badge: .twitch, placement: BadgePlacement(x: 0.3, y: 0.7, size: 1.4))
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
        try store.saveCreatorProfile(ShortBranding(kick: "channel"))
        XCTAssertNoThrow(try store.validateExport(store.project))
        try store.saveCreatorProfile(ShortBranding()); XCTAssertThrowsError(try store.validateExport(store.project))
        store.project.selectWorkflow(.youtubeVideo); XCTAssertNoThrow(try store.validateExport(store.project))
    }
}
