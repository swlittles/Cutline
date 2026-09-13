import XCTest
import CutlineCore
@testable import Cutline
@MainActor final class UpdateServiceTests: XCTestCase {
    final class Backend: UpdateBackend {
        var onChange: ((UpdateState) -> Void)?
        var starts = 0; var checks = 0; var preferences: [Bool] = []
        func start() { starts += 1 }
        func check() { checks += 1 }
        func setAutomaticChecks(_ enabled: Bool) { preferences.append(enabled) }
    }
    func testDevelopmentNeverConstructsOrStartsNetworkBackend() {
        var creations = 0
        let service = UpdateService(environment: AppEnvironment(bundleIdentifier: "studio.cutline.editor.dev")) { creations += 1; return Backend() }
        service.start(); service.start(); service.check(); service.setAutomaticChecks(true)
        XCTAssertEqual(creations, 0); XCTAssertFalse(service.enabled); XCTAssertFalse(service.state.canCheck)
    }
    func testReleaseStartsOnlyOnce() {
        let backend = Backend(); let service = release(backend)
        service.start(); service.start(); XCTAssertEqual(backend.starts, 1)
    }
    func testCheckWaitsForSparkleReadiness() {
        let backend = Backend(); let service = release(backend)
        service.check(); service.start(); service.check(); XCTAssertEqual(backend.checks, 0)
        backend.onChange?(UpdateState(canCheck: true)); service.check(); XCTAssertEqual(backend.checks, 1)
        backend.onChange?(UpdateState(canCheck: false)); service.check(); XCTAssertEqual(backend.checks, 1)
    }
    func testAutomaticCheckPreferenceIsForwardedAndObserved() {
        let backend = Backend(); let service = release(backend); service.start()
        service.setAutomaticChecks(true); service.setAutomaticChecks(false)
        XCTAssertEqual(backend.preferences, [true,false])
        backend.onChange?(UpdateState(automaticChecks: true)); XCTAssertTrue(service.state.automaticChecks)
    }
    func testLastCheckStateIsReported() {
        let backend = Backend(); let service = release(backend); service.start()
        let date = Date(timeIntervalSince1970: 123)
        backend.onChange?(UpdateState(canCheck: true, lastCheck: date))
        XCTAssertEqual(service.state.lastCheck, date)
    }
    private func release(_ backend: Backend) -> UpdateService {
        UpdateService(environment: AppEnvironment(bundleIdentifier: "studio.cutline.editor")) { backend }
    }
}
