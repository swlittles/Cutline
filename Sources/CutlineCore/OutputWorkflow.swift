import Foundation

public enum OutputWorkflow: String, Codable, CaseIterable, Identifiable, Sendable {
    case mobileShort, youtubeVideo
    public var id: String { rawValue }
    public var label: String { self == .mobileShort ? "Mobile Short · 9:16" : "YouTube Video · 16:9" }
    public var format: CanvasFormat { self == .mobileShort ? .portrait : .landscape }
}

/// Source-frame coordinates, normalized from the top-left. Confirm on each recording.
public struct ShortFraming: Codable, Equatable, Sendable {
    public var camera = ClipScanRegion(x: 0, y: 0.75, width: 0.25, height: 0.25)
    public var gameplay = ClipScanRegion()
    public var containGameplay = false
    public var confirmed = false
    public init() {}
    public func validate() throws {
        guard camera.valid, gameplay.valid else { throw EditError.invalid("Facecam and gameplay crops must be inside the source frame.") }
    }
}

/// Pixel boundaries are rounded once so adjacent panels never overlap or leave seams.
public struct ShortGeometry: Equatable, Sendable {
    public let camera: CGRect, brand: CGRect, gameplay: CGRect
    public init(size: CGSize) {
        let cameraEnd = (size.height * 0.30).rounded()
        let brandEnd = (size.height * 0.32).rounded()
        camera = CGRect(x: 0, y: size.height - cameraEnd, width: size.width, height: cameraEnd)
        brand = CGRect(x: 0, y: size.height - brandEnd, width: size.width, height: brandEnd - cameraEnd)
        gameplay = CGRect(x: 0, y: 0, width: size.width, height: size.height - brandEnd)
    }
}

public extension EditProject {
    var outputFormat: CanvasFormat { workflow?.format ?? format }
    mutating func selectWorkflow(_ value: OutputWorkflow) {
        let changed = workflow != value
        workflow = value; format = value.format
        if changed && value == .mobileShort { options.fps = 30 }
    }
    func hook(for clip: TimelineClip) -> String { (clip.shortHook ?? shortHook ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func validateForExport() throws {
        try validate()
        guard let workflow else { throw EditError.invalid("Choose Mobile Short or YouTube Video in the Inspector before exporting this older project.") }
        if workflow == .mobileShort {
            for clip in clips {
                let text = hook(for: clip)
                guard !text.isEmpty, text.count <= 80, !text.contains(where: { $0.isNewline }) else {
                    throw EditError.invalid("Every short needs an on-screen hook (1–80 characters, one line of text). Set it in the Inspector or clip card.")
                }
                guard media.first(where: { $0.id == clip.mediaID })?.shortFraming?.confirmed == true else {
                    throw EditError.invalid("Check the facecam and gameplay crops for every recording in Short framing before exporting.")
                }
            }
        }
    }
}
