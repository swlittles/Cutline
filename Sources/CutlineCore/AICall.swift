import Foundation

/// The request plumbing every AI step shares: building a structured-output request for OpenRouter
/// or the Claude API, retries, and running many requests a few at a time where one failure doesn't
/// sink the rest.
public enum AICall {
    struct Failure: Error { var underlying: Error; var fatal: Bool }
    /// One piece of a user message. Frames are sent as JPEG.
    enum Part { case text(String), jpeg(Data) }

    /// A strict JSON-schema object with every property required.
    static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }
    static let string: [String: Any] = ["type": "string"]
    static let number: [String: Any] = ["type": "number"]

    static func request(model: String, system: String, user: String, schemaName: String, schema: [String: Any], maxTokens: Int, apiKey: String,
                        provider: AIProvider = .openRouter, effort: String = "low", timeout: TimeInterval = 240) throws -> URLRequest {
        try request(model: model, system: system, parts: [.text(user)], schemaName: schemaName, schema: schema, maxTokens: maxTokens, apiKey: apiKey, provider: provider, effort: effort, timeout: timeout)
    }

    /// `effort` only applies to Claude, which thinks before answering; the cheaper steps use "low".
    static func request(model: String, system: String, parts: [Part], schemaName: String, schema: [String: Any], maxTokens: Int, apiKey: String,
                        provider: AIProvider = .openRouter, effort: String = "low", timeout: TimeInterval = 240) throws -> URLRequest {
        var request = URLRequest(url: provider.endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch provider {
        case .openRouter:
            let content: Any
            if parts.count == 1, case .text(let text) = parts[0] { content = text }
            else {
                content = parts.map { part -> [String: Any] in
                    switch part {
                    case .text(let text): return ["type": "text", "text": text]
                    case .jpeg(let data): return ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]]
                    }
                }
            }
            body = [
                "model": model, "stream": false, "max_tokens": maxTokens,
                "messages": [["role": "system", "content": system], ["role": "user", "content": content]],
                "provider": ["require_parameters": true],
                "response_format": ["type": "json_schema", "json_schema": ["name": schemaName, "strict": true, "schema": schema]]
            ]
            request.timeoutInterval = timeout
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("Cutline", forHTTPHeaderField: "X-Title")
        case .claude:
            let content: [[String: Any]] = parts.map { part in
                switch part {
                case .text(let text): return ["type": "text", "text": text]
                case .jpeg(let data): return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
                }
            }
            var output: [String: Any] = ["format": ["type": "json_schema", "schema": schema]]
            if takesEffort(model) { output["effort"] = effort }
            // Thinking counts toward max_tokens, so leave room beyond the answer itself.
            var claude: [String: Any] = ["model": model, "max_tokens": max(maxTokens, 16000), "system": system,
                                         "messages": [["role": "user", "content": content]], "output_config": output]
            if fallsBack(model) {
                // If a safety check declines the request, the API retries it on a suitable model.
                claude["fallbacks"] = "default"
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
            body = claude
            request.timeoutInterval = max(timeout, 300)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }
    /// Claude models from the 4.6 generation on accept an effort level; older ones reject it.
    static func takesEffort(_ model: String) -> Bool {
        ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
         "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5"].contains { model.hasPrefix($0) }
    }
    static func fallsBack(_ model: String) -> Bool { ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model) }

    /// The outermost JSON object in a reply. Some providers wrap it in a code fence or a sentence despite the schema.
    static func json(in content: String) -> Data? {
        guard let open = content.firstIndex(of: "{"), let close = content.lastIndex(of: "}"), open < close else { return nil }
        return Data(content[open...close].utf8)
    }

    /// The reply's text. A Claude refusal is final for this request but doesn't stop the others.
    static func content(of data: Data, provider: AIProvider) throws -> String {
        switch provider {
        case .openRouter:
            struct Envelope: Decodable { struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }; var choices: [Choice] }
            guard let content = (try? JSONDecoder().decode(Envelope.self, from: data))?.choices.first?.message.content, !content.isEmpty else {
                throw EditError.invalid("The AI returned an empty response.")
            }
            return content
        case .claude:
            struct Reply: Decodable { struct Block: Decodable { var type: String; var text: String? }; var content: [Block]?; var stop_reason: String? }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw EditError.invalid("Claude returned an unreadable response.") }
            if reply.stop_reason == "refusal" { throw Failure(underlying: EditError.invalid("Claude declined this request."), fatal: false) }
            let text = (reply.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
            guard !text.isEmpty else { throw EditError.invalid(reply.stop_reason == "max_tokens" ? "Claude ran out of room before answering." : "The AI returned an empty response.") }
            return text
        }
    }
    /// The provider's own explanation of a failed request, when it sent one.
    static func detail(_ data: Data) -> String? {
        struct Body: Decodable { struct Detail: Decodable { var message: String? }; var error: Detail? }
        guard let message = (try? JSONDecoder().decode(Body.self, from: data))?.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        return String(message.prefix(240))
    }

    /// Up to three attempts; rate limits, server errors and unreadable replies wait a moment first.
    /// A rejected key, missing credits or an unsupported model fail at once.
    static func send<T>(_ request: URLRequest, session: URLSession, parse: (String) throws -> T) async throws -> T {
        let provider: AIProvider = request.url?.host == "api.anthropic.com" ? .claude : .openRouter
        let images = request.httpBody.map { String(decoding: $0, as: UTF8.self).contains("base64") } == true
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EditError.invalid("\(provider.name) returned no HTTP response.") }
                guard (200..<300).contains(http.statusCode) else {
                    let detail = detail(data).map { " \($0)" } ?? ""
                    switch http.statusCode {
                    case 401, 403: throw Failure(underlying: EditError.invalid("\(provider.name) rejected the request (HTTP \(http.statusCode)). Check your API key and model access."), fatal: true)
                    case 402: throw Failure(underlying: EditError.invalid("Your \(provider.account) account needs credits."), fatal: true)
                    case 400, 404, 413: throw Failure(underlying: EditError.invalid("\(provider.name) couldn't run this model (HTTP \(http.statusCode)). Check the model ID and that it supports structured output\(images ? " and images" : "").\(detail)"), fatal: true)
                    default: throw EditError.invalid("\(provider.name) request failed (HTTP \(http.statusCode)). Try again in a moment.")
                    }
                }
                return try parse(try content(of: data, provider: provider))
            } catch let error as Failure {
                throw error
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    /// Runs `count` jobs, `concurrency` at a time. A job that fails is `nil`; fatal errors and
    /// cancellation stop everything, and if every job fails the last error is thrown.
    static func batch<T: Sendable>(_ count: Int, concurrency: Int, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                                   _ job: @escaping @Sendable (Int) async throws -> T) async throws -> [T?] {
        guard count > 0 else { return [] }
        let done = Counter()
        var results: [T?] = Array(repeating: nil, count: count)
        var lastError: Error?
        try await withThrowingTaskGroup(of: (Int, Result<T, Error>).self) { group in
            var next = 0
            func add() {
                guard next < count else { return }
                let index = next; next += 1
                group.addTask {
                    let result: Result<T, Error>
                    do { result = .success(try await job(index)) } catch { result = .failure(error) }
                    progress(done.increment(), count)
                    return (index, result)
                }
            }
            for _ in 0..<min(concurrency, count) { add() }
            while let (index, result) = try await group.next() {
                switch result {
                case .success(let value): results[index] = value
                case .failure(let error):
                    if error is CancellationError || (error as? Failure)?.fatal == true { group.cancelAll(); throw (error as? Failure)?.underlying ?? error }
                    lastError = error
                }
                add()
            }
        }
        try Task.checkCancellation()
        if results.allSatisfy({ $0 == nil }), let lastError { throw (lastError as? Failure)?.underlying ?? lastError }
        return results
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
