import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct GenerationModel: Decodable, Identifiable, Sendable {
    public struct Capability: Decodable, Sendable { public var type: String; public var values: [String]? }
    public var id: String
    public var name: String
    public var supported_parameters: [String: Capability]?
    public var supported_durations: [Int]?
    public var supported_resolutions: [String]?
    public var supported_aspect_ratios: [String]?
    public var pricing_skus: [String: String]?
    public var ratios: [String] { supported_aspect_ratios ?? supported_parameters?["aspect_ratio"]?.values ?? [] }
    public var resolutions: [String] { supported_resolutions ?? supported_parameters?["resolution"]?.values ?? [] }
}

public enum GenerationKind: String, CaseIterable, Codable, Sendable { case image, video }

/// Persisted before polling; credentials are never serialized. Completed assets survive project changes.
public struct GenerationRecord: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: GenerationKind
    public var model: String
    public var prompt: String
    public var created = Date()
    public var remoteID: String?
    public var status = "starting"
    public var cost: Double?
    public var assetName: String?
    public var directory: URL { LocalTools.support.appendingPathComponent("Generated/\(id.uuidString)", isDirectory: true) }
    public var assetURL: URL? { assetName.map { directory.appendingPathComponent($0) } }
    public init(kind: GenerationKind, model: String, prompt: String) { self.kind = kind; self.model = model; self.prompt = prompt }
    public func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("generation.json"), options: .atomic)
    }
    public static func saved() -> [GenerationRecord] {
        let root = LocalTools.support.appendingPathComponent("Generated")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("generation.json")), let record = try? JSONDecoder().decode(Self.self, from: data), record.directory.standardizedFileURL == folder.standardizedFileURL,
                  record.assetName == nil || ["image.png", "video.mp4"].contains(record.assetName!) else { return nil }
            return record
        }.sorted { $0.created > $1.created }
    }
}

public enum MediaGeneration {
    private static let base = URL(string: "https://openrouter.ai/api/v1/")!
    public static func catalog(_ kind: GenerationKind, session: URLSession = .shared) async throws -> [GenerationModel] {
        struct Catalog: Decodable { var data: [GenerationModel] }
        let (data, response) = try await session.data(from: base.appendingPathComponent(kind == .image ? "images/models" : "videos/models"))
        try check(response)
        return try JSONDecoder().decode(Catalog.self, from: data).data.filter { kind == .image || !($0.supported_durations ?? []).isEmpty }.sorted { $0.name < $1.name }
    }
    public static func request(kind: GenerationKind, model: GenerationModel, prompt: String, ratio: String, resolution: String, duration: Int, apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 12000 else { throw EditError.invalid("Enter an API key and a prompt of 1–12,000 characters.") }
        var body: [String: Any] = ["model": model.id, "prompt": prompt]
        if !ratio.isEmpty { guard model.ratios.contains(ratio) else { throw EditError.invalid("This model does not support that aspect ratio.") }; body["aspect_ratio"] = ratio }
        if !resolution.isEmpty { guard model.resolutions.contains(resolution) else { throw EditError.invalid("This model does not support that resolution.") }; body["resolution"] = resolution }
        if kind == .video {
            guard (model.supported_durations ?? []).contains(duration) else { throw EditError.invalid("Choose a duration supported by this video model.") }
            body["duration"] = duration
        }
        var request = authenticated(base.appendingPathComponent(kind == .image ? "images" : "videos"), key: apiKey)
        request.httpMethod = "POST"; request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    public static func image(request: URLRequest, record: GenerationRecord, session: URLSession = .shared) async throws -> GenerationRecord {
        let (data, response) = try await session.data(for: request); try check(response); try Task.checkCancellation()
        struct Result: Decodable { struct Item: Decodable { var b64_json: String }; var data: [Item]; var usage: Usage? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard let encoded = result.data.first?.b64_json, encoded.count < 100_000_000, let bytes = Data(base64Encoded: encoded) else { throw EditError.invalid("The provider returned no usable image.") }
        let png = try normalizedPNG(bytes)
        var completed = record; completed.status = "completed"; completed.assetName = "image.png"; completed.cost = result.usage?.cost
        try record.save()
        try png.write(to: completed.assetURL!, options: .atomic); try completed.save()
        return completed
    }
    /// Decode only supported raster formats. Normalize content, rather than trusting the MIME/extension.
    public static func normalizedPNG(_ bytes: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "org.webmproject.webp", "public.heic", "public.tiff"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary) else { throw EditError.invalid("The result is not a supported raster image, or exceeds 64 megapixels.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw EditError.invalid("Could not prepare the generated image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EditError.invalid("Could not encode the image.") }
        return output as Data
    }
    public static func submitVideo(request: URLRequest, record: GenerationRecord, session: URLSession = .shared) async throws -> GenerationRecord {
        // No automatic retries: a second POST can create a second billable job.
        let (data, response) = try await session.data(for: request); try check(response)
        let job = try JSONDecoder().decode(VideoJob.self, from: data)
        _ = try jobURL(job.id)
        var next = record; next.remoteID = job.id; next.status = job.status
        try next.save()
        return next
    }
    public static func pollVideo(_ record: GenerationRecord, apiKey: String, session: URLSession = .shared, interval: UInt64 = 30_000_000_000, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> GenerationRecord {
        guard let id = record.remoteID else { throw EditError.invalid("This job has no provider ID to resume.") }
        let url = try jobURL(id)
        var next = record
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: authenticated(url, key: apiKey)); try check(response)
            let job = try JSONDecoder().decode(VideoJob.self, from: data)
            guard job.id == id else { throw EditError.invalid("The provider returned a different video job.") }
            next.status = job.status; next.cost = job.usage?.cost ?? next.cost; try next.save(); progress(job.status)
            switch job.status {
            case "completed":
                // Construct our own endpoint; never send the user's key to a URL from generated content.
                let content = url.appendingPathComponent("content").appending(queryItems: [URLQueryItem(name: "index", value: "0")])
                let (temporary, response) = try await session.download(for: authenticated(content, key: apiKey))
                defer { try? FileManager.default.removeItem(at: temporary) }
                try check(response); try Task.checkCancellation()
                // CFNetwork uses a .tmp suffix; AVFoundation needs a movie extension
                // when loading a local download. Validate the bytes before publishing it.
                let staging = next.directory.appendingPathComponent("download-\(UUID()).mp4")
                try FileManager.default.moveItem(at: temporary, to: staging)
                defer { try? FileManager.default.removeItem(at: staging) }
                _ = try await CompositionEngine.inspect(staging)
                next.assetName = "video.mp4"
                if FileManager.default.fileExists(atPath: next.assetURL!.path) { _ = try FileManager.default.replaceItemAt(next.assetURL!, withItemAt: staging) }
                else { try FileManager.default.moveItem(at: staging, to: next.assetURL!) }
                try next.save(); return next
            case "failed", "cancelled", "expired": throw EditError.invalid("Video generation \(job.status). Check this job in your OpenRouter activity.")
            case "pending", "in_progress", "processing", "queued": try await Task.sleep(nanoseconds: interval)
            default: throw EditError.invalid("Unknown video job status: \(job.status). The job is saved; resume later.")
            }
        }
    }
    public static func jobURL(_ id: String) throws -> URL {
        guard !id.isEmpty, id.count <= 200, id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw EditError.invalid("The video job ID is invalid.") }
        return base.appendingPathComponent("videos").appendingPathComponent(id)
    }
    private struct Usage: Decodable { var cost: Double? }
    private struct VideoJob: Decodable { var id: String; var status: String; var usage: Usage? }
    private static func authenticated(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url); request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("Cutline", forHTTPHeaderField: "X-Title")
        return request
    }
    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw EditError.invalid("No response from OpenRouter.") }
        guard (200..<300).contains(http.statusCode) else {
            let hint: String
            switch http.statusCode { case 401, 403: hint = "Check your API key and model access."; case 402: hint = "Your account needs credits."; case 429: hint = "Rate limit reached. Retry later."; default: hint = "Check the model's options and your OpenRouter activity before retrying." }
            throw EditError.invalid("OpenRouter failed (HTTP \(http.statusCode)). \(hint)")
        }
    }
}

public enum StillImageClip {
    /// Creates an editable five-second clip; the original artwork remains available alongside it.
    public static func make(from image: URL, directory: URL? = nil) async throws -> URL {
        let ffmpeg = try LocalTools.require("ffmpeg")
        let folder = directory ?? LocalTools.support.appendingPathComponent("Stills/\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("still.mp4")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let source = folder.appendingPathComponent("source.png")
        try MediaGeneration.normalizedPNG(Data(contentsOf: image)).write(to: source, options: .atomic)
        let temporary = folder.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-loop", "1", "-i", source.path, "-t", "5", "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2", "-r", "30", "-c:v", "libx264", "-pix_fmt", "yuv420p", temporary.path])
        try Task.checkCancellation(); try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}
