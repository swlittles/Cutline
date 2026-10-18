import XCTest
import CutlineCore

extension EditorUITests {
    func testCreatorBrandingSavesLocallyAndReloadsWithoutChangingProject() throws {
        launch()
        app.typeKey(",", modifierFlags: .command)
        let kick = app.textFields["branding.kick"]
        XCTAssertTrue(kick.waitForExistence(timeout: 5)); XCTAssertEqual(kick.value as? String, "")
        edit(kick, "https://kick.com/creator")
        edit(app.textFields["branding.twitch"], "@creator_tv")
        app.buttons["creator.save"].click()
        assertLabel("creator.status", "Saved on this Mac.")
        XCTAssertEqual(try CreatorProfileStore.load(from: root), ShortBranding(kick: "creator", twitch: "creator_tv"))
        XCTAssertEqual(try EditProject.read(from: projectURL), project)
        app.terminate(); launch(); app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(kick.waitForExistence(timeout: 5)); XCTAssertEqual(kick.value as? String, "creator")
        edit(kick, ""); app.buttons["creator.save"].click()
        XCTAssertTrue(try CreatorProfileStore.load(from: root).kick.isEmpty)
    }

    func testChannelBadgeChoosesPlatformAndIsDraggedAndSizedIntoPlace() throws {
        try CreatorProfileStore.save(ShortBranding(kick: "creator", twitch: "creator_tv"), to: root)
        launch()
        app.typeKey(",", modifierFlags: .command)
        let badge = app.descendants(matching: .any)["preview.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(badge.label.contains("@creator"), badge.label)
        app.radioButtons["Twitch"].click()
        let switched = expectation(for: NSPredicate(format: "label CONTAINS %@", "@creator_tv"), evaluatedWith: badge)
        wait(for: [switched], timeout: 5)
        // Drag the badge toward the bottom of the short and make it bigger.
        let start = badge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
        app.sliders["branding.size"].adjust(toNormalizedSliderPosition: 0.75)
        app.buttons["creator.save"].click()
        assertLabel("creator.status", "Saved on this Mac.")
        let saved = try CreatorProfileStore.load(from: root)
        XCTAssertEqual(saved.badge, .twitch)
        XCTAssertGreaterThan(saved.placement.y, 0.6, "dragged down from the divider")
        XCTAssertEqual(saved.placement.x, 0.5, accuracy: 0.05)
        XCTAssertGreaterThan(saved.placement.size, 1.5)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); screenshot.name = "Channel badge settings"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["branding.reset"].click(); app.buttons["creator.save"].click()
        XCTAssertEqual(try CreatorProfileStore.load(from: root).placement, BadgePlacement())
    }
}
