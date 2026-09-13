#if DEBUG
import Foundation
import CutlineCore

/// Deterministic external-service boundary, compiled out of release builds.
/// The UI and editing/rendering code paths remain the production implementations.
enum UITestRuntime {
    static func install() {
        guard let root = LocalTools.testingRoot else { return }
        URLProtocol.registerClass(UITestProtocol.self)
        try? Data("debug-isolated".utf8).write(to: root.appendingPathComponent("runtime-ready"), options: .atomic)
    }
}
private final class UITestProtocol: URLProtocol {
    private static let logLock = NSLock()
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { LocalTools.testingRoot != nil && ["https", "http"].contains(request.url?.scheme ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { pending?.cancel(); pending = nil }
    override func startLoading() {
        guard let root = LocalTools.testingRoot else { return }
        let mode = (try? String(contentsOf: root.appendingPathComponent("ai-mode"), encoding: .utf8)) ?? "success"
        Self.logLock.lock()
        let log = root.appendingPathComponent("request-log")
        let entry = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")\n"
        let previous = (try? Data(contentsOf: log)) ?? Data()
        try? (previous + Data(entry.utf8)).write(to: log, options: .atomic)
        Self.logLock.unlock()
        var raw: Data?
        var status = 200
        var object: [String: Any] = [:]
        let path = request.url?.path ?? ""
        if path.contains("/chat/completions") {
            if mode == "auth" { status = 401 }
            else if mode == "invalid" { object = ["choices": [["message": ["content": "invalid JSON"]]]] }
            else {
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); var data = Data(); while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(bytes, count: count) }; body = data }
                let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
                let regex = try! NSRegularExpression(pattern: "id=([A-Fa-f0-9-]{36})")
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                let ids = matches.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
                let proposal: [String: Any] = ["summary": "A strong team highlight.", "highlights": [["start": 0.5, "end": 3.0, "title": "Castle comeback", "reason": "The commentary describes a coordinated push.", "score": 92]], "titles": ["The castle comeback"], "captionEdits": ids.prefix(1).map { ["id": $0, "text": "Push the castle together!"] }]
                let encoded = try! JSONSerialization.data(withJSONObject: proposal)
                object = ["choices": [["message": ["content": String(data: encoded, encoding: .utf8)!]]]]
            }
        } else if path.hasSuffix("/images/models") {
            object = ["data": [["id": "test/image", "name": "Test image", "supported_parameters": ["aspect_ratio": ["type": "enum", "values": ["16:9", "9:16"]]]]]]
        } else if path.hasSuffix("/videos/models") {
            object = ["data": [["id": "test/video", "name": "Test video", "supported_durations": [4,8], "supported_resolutions": ["720p"], "supported_aspect_ratios": ["16:9"]]]]
        } else if path.hasSuffix("/images") {
            let bytes = (try? Data(contentsOf: root.appendingPathComponent("artwork.png"))) ?? Data()
            object = ["data": [["b64_json": bytes.base64EncodedString()]], "usage": ["cost": 0.01]]
        } else if path.hasSuffix("/videos"), request.httpMethod == "POST" {
            status = 202; object = ["id": "job_ui_test", "status": "pending"]
        } else if path.hasSuffix("/videos/job_ui_test/content") {
            raw = (try? Data(contentsOf: root.appendingPathComponent("gameplay.mp4"))) ?? Data()
        } else if path.hasSuffix("/videos/job_ui_test") {
            object = ["id": "job_ui_test", "status": mode == "video-pending" ? "pending" : mode == "video-complete" ? "completed" : "failed"]
        } else {
            // All other network access is denied in UI tests, including model downloads.
            status = 503; object = ["error": "No fixture for this request"]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": raw == nil ? "application/json" : "video/mp4"])!
        let data = raw ?? ((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.isCancelled != true else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data); self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (mode == "slow" ? 10 : 0.05), execute: work)
    }
}
#endif
