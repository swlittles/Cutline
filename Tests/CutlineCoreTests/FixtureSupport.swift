import Foundation
import XCTest
@testable import CutlineCore

final class FixtureOwner {}
enum Fixtures {
    static var directory: URL {
        #if SWIFT_PACKAGE
        return Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        #else
        let root = Bundle(for: FixtureOwner.self).resourceURL!
        let folder = root.appendingPathComponent("Fixtures")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : root
        #endif
    }
    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    static func project() -> EditProject {
        var project = EditProject()
        let media = MediaItem(url: url("gameplay.mp4"), duration: 5)
        project.media = [media]; project.clips = [TimelineClip(mediaID: media.id, sourceOut: 5)]
        project.options.resolution = 720
        return project
    }
    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
}
