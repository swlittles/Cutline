import XCTest
import CutlineCore

extension EditorUITests {
    func testCreatorBrandingSavesLocallyAndReloadsWithoutChangingProject() throws {
        launch()
        app.typeKey(",", modifierFlags: .command)
        let field = app.textFields["creator.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "")
        edit(field, "example.test/creator")
        app.buttons["creator.save"].click()
        assertLabel("creator.status", "Branding saved on this Mac.")
        XCTAssertEqual(try CreatorProfileStore.load(from: root).text, "example.test/creator")
        XCTAssertEqual(try EditProject.read(from: projectURL), project)
        app.terminate(); launch(); app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "example.test/creator")
        edit(field, ""); app.buttons["creator.save"].click()
        XCTAssertTrue(try CreatorProfileStore.load(from: root).text.isEmpty)
    }
}
