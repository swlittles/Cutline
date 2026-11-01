import Foundation

/// The OpenRouter plumbing the AI clip steps share: request building, retries, and running
/// many requests a few at a time where one failure doesn't sink the rest.
public enum OpenRouterCall {
    struct Failure: Error { var underlying: Error; var fatal: Bool }
    struct Envelope: Decodable { struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }; var choices: [Choice] }

    /// A strict JSON-schema object with every property required.
    static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }
    static let string: [String: Any] = ["type": "string"]
    static let number: [String: Any] = ["type": "number"]

    static func request(model: String, system: String, user: Any, schemaName: String, schema: [String: Any], maxTokens: Int, apiKey: String, timeout: TimeInterval = 240) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model, "stream": false, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "provider": ["require_parameters": true],
            "response_format": ["type": "json_schema", "json_schema": ["name": schemaName, "strict": true, "schema": schema]]
        ]
        var request = URLRequest(url: EditingAssistant.endpoint); request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Cutline", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    /// The outermost JSON object in a reply. Some providers wrap it in a code fence or a sentence despite the schema.
    static func json(in content: String) -> Data? {
        guard let open = content.firstIndex(of: "{"), let close = content.lastIndex(of: "}"), open < close else { return nil }
        return Data(content[open...close].utf8)
    }

    /// Up to three attempts; rate limits, server errors and unreadable replies wait a moment first.
    /// A rejected key, missing credits or an unsupported model fail at once.
    static func send<T>(_ request: URLRequest, session: URLSession, parse: (String) throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EditError.invalid("OpenRouter returned no HTTP response.") }
                guard (200..<300).contains(http.statusCode) else {
                    switch http.statusCode {
                    case 401, 403: throw Failure(underlying: EditError.invalid("OpenRouter rejected the request (HTTP \(http.statusCode)). Check your API key and model access."), fatal: true)
                    case 402: throw Failure(underlying: EditError.invalid("Your OpenRouter account needs credits."), fatal: true)
                    case 400, 404: throw Failure(underlying: EditError.invalid("OpenRouter couldn't run this model (HTTP \(http.statusCode)). Check the model ID and that it supports structured output\(request.httpBody.map { String(decoding: $0, as: UTF8.self).contains("image_url") } == true ? " and images" : "")."), fatal: true)
                    default: throw EditError.invalid("OpenRouter request failed (HTTP \(http.statusCode)). Try again in a moment.")
                    }
                }
                guard let content = (try? JSONDecoder().decode(Envelope.self, from: data))?.choices.first?.message.content, !content.isEmpty else {
                    throw EditError.invalid("The AI returned an empty response.")
                }
                return try parse(content)
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
