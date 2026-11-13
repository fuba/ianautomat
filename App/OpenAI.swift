import Foundation

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum OpenAI {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 150
        config.timeoutIntervalForResource = 150
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func request(_ url: String, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func encoded(_ items: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return items.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }

    static func form(_ endpoint: String, _ fields: [String: String]) -> URLRequest {
        var request = request(issuer + endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(encoded(fields).utf8)
        return request
    }

    static func checked(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AppError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429, let value = http.value(forHTTPHeaderField: "Retry-After"),
               let seconds = retryAfter(value) {
                throw RetryAfter(seconds: seconds)
            }
            throw AppError.http(http.statusCode)
        }
    }

    static func retryAfter(_ value: String) -> TimeInterval? {
        if let delay = TimeInterval(value), delay.isFinite, delay >= 0 { return delay }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    static func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try checked(response)
        guard data.count <= 2_000_000 else { throw AppError.badResponse }
        return data
    }

    static func models(token: String) async throws -> [ModelOption] {
        struct Catalog: Decodable { let models: [ModelOption] }
        let data = try await data(request(resource + "/models", token: token))
        let models = try JSONDecoder().decode(Catalog.self, from: data).models
        var seen = Set<String>()
        let visible = models.filter { $0.visibility == "list" && seen.insert($0.slug).inserted }
        guard !visible.isEmpty else { throw AppError.noModels }
        return visible
    }

    static func next(run: GoalRun, model: String, token: String, language: String) async throws -> ResponseResult {
        let instructions = """
        You build useful native tools inside the user's iPhone app. Respond in \(language).
        Each step returns one action. Use note for readable text, checklist for up to 40 items,
        or calculator for a numeric operation on a user-entered list (sum, subtract, multiply,
        divide, average, minimum, maximum). Body explains a tool's purpose or holds note text.
        Report done when the goal is met. Report blocked when it requires another app, browsing,
        device access, code execution, or another capability unavailable here. You cannot read
        Notification Center. If the user supplies notification text in the goal, summarize that text.
        If the goal requires unseen notifications, explain the limit and ask for the notification text.
        Never claim to have performed unavailable actions. Do not produce code for execution, URLs to open, or instructions
        for attacks. Use empty strings or an empty items list for fields the action does not need.
        Avoid creating tools that are already listed in the input.
        """
        let context: [String: Any] = [
            "goal": run.goal,
            "existing_tools": run.artifacts.map { ["kind": $0.kind.rawValue, "title": $0.title] }
        ]
        let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
        let fields: [String: Any] = [
            "action": ["type": "string", "enum": ["note", "checklist", "calculator", "done", "blocked"]],
            "title": ["type": "string"], "message": ["type": "string"],
            "body": ["type": "string"], "operation": ["type": "string"],
            "items": ["type": "array", "items": ["type": "string"]]
        ]
        let schema: [String: Any] = [
            "type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false
        ]
        let payload: [String: Any] = [
            "model": model, "instructions": instructions, "store": false, "stream": true,
            "input": [["role": "user", "content": String(decoding: contextData, as: UTF8.self)]],
            "text": ["format": ["type": "json_schema", "name": "goal_action", "strict": true, "schema": schema]]
        ]
        var request = request(resource + "/responses", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw AppError.badResponse }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            // Bound error reads and never include the raw response body in a user log.
            for try await byte in bytes {
                body.append(byte)
                if body.count == 16_384 { break }
            }
            throw ResponseFailure(
                status: http.statusCode, requestID: requestID, body: body,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(retryAfter)
            )
        }
        guard http.mimeType == "text/event-stream" else {
            throw ResponseFailure(status: http.statusCode, requestID: requestID, fields: nil,
                                  reason: .unexpectedContentType)
        }
        var stream = ResponseStream(requestID: requestID)
        var size = 0
        for try await byte in bytes {
            if size.isMultiple(of: 4096) { try Task.checkCancellation() }
            size += 1
            guard size <= 4_000_000 else { throw AppError.badResponse }
            try stream.receive(byte)
            if stream.completed { break }
        }
        try Task.checkCancellation()
        return try stream.result()
    }
}

struct ModelOption: Codable, Identifiable, Equatable {
    let slug: String
    let displayName: String
    let visibility: String

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, visibility
        case displayName = "display_name"
    }
}

struct RetryAfter: LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? { String(localized: "OpenAI returned HTTP 429.") }
}

struct ResponseResult {
    let text: String
    let tokens: Int?
}

struct ResponseFailure: LocalizedError {
    let status: Int?
    let requestID: String?
    let code: String?
    let parameter: String?
    let retryAfter: TimeInterval?
    private let reason: AppError?

    init(status: Int, requestID: String?, body: Data, retryAfter: TimeInterval? = nil) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        self.init(status: status, requestID: requestID, fields: json?["error"] as? [String: Any],
                  retryAfter: retryAfter)
    }

    init(status: Int? = nil, requestID: String?, fields: [String: Any]?,
         retryAfter: TimeInterval? = nil, reason: AppError? = nil) {
        self.status = status
        self.requestID = Self.label(requestID, pattern: /req_[A-Za-z0-9_-]+/)
        code = Self.label(fields?["code"] as? String, pattern: /[a-z][a-z0-9_]*/)
        parameter = Self.label(fields?["param"] as? String, pattern: /[a-z][a-zA-Z0-9_.\[\]]*/)
        self.retryAfter = retryAfter
        self.reason = reason
    }

    var retryable: Bool {
        if code == "subscription_sharing_usage_limit_exceeded" || code == "subscription_sharing_user_not_eligible" {
            return false
        }
        if let retryAfter, retryAfter > 86_400 { return false }
        return code == "server_error" || code == "rate_limit_exceeded" ||
            code == "subscription_sharing_usage_unavailable" ||
            status.map { [408, 429, 500, 502, 503, 504].contains($0) } == true
    }

    var errorDescription: String? {
        let summary: String
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            summary = AppError.usageLimit.localizedDescription
        case "subscription_sharing_user_not_eligible":
            summary = String(localized: "ChatGPT plan usage is unavailable for this account or workspace.")
        case "subscription_sharing_unsupported_capability":
            summary = String(localized: "This ChatGPT model or plan did not accept a requested feature.")
        default:
            summary = reason?.localizedDescription ?? String(localized: "OpenAI could not complete this request.")
        }
        let details = [status.map { "HTTP \($0)" }, code, parameter, requestID].compactMap { $0 }
        return details.isEmpty ? summary : summary + " [" + details.joined(separator: " · ") + "]"
    }

    private static func label(_ value: String?, pattern: Regex<Substring>) -> String? {
        guard let value, value.utf8.count <= 128,
              value.wholeMatch(of: pattern) != nil else { return nil }
        return value
    }
}

struct ResponseStream {
    private let requestID: String?
    private var final: ResponseResult?
    private var line: [UInt8] = []
    private var event: [String] = []
    private var firstLine = true
    private var afterCR = false

    init(requestID: String? = nil) { self.requestID = requestID }

    var completed: Bool { final != nil }

    mutating func receive(_ byte: UInt8) throws {
        // AsyncLineSequence omits empty lines, which delimit SSE events.
        if byte == 10 && afterCR {
            afterCR = false
            return
        }
        afterCR = byte == 13
        guard byte == 10 || byte == 13 else {
            line.append(byte)
            return
        }
        if firstLine {
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
            firstLine = false
        }
        if line.isEmpty {
            if !event.isEmpty { try consume(event.joined(separator: "\n")) }
            event.removeAll(keepingCapacity: true)
        } else if let field = String(bytes: line, encoding: .utf8) {
            if field == "data" { event.append("") }
            if field.hasPrefix("data:") {
                let value = field.dropFirst(5)
                event.append(String(value.first == " " ? value.dropFirst() : value))
            }
        }
        line.removeAll(keepingCapacity: true)
    }

    mutating func consume(_ json: String) throws {
        guard !json.isEmpty, json != "[DONE]" else { return }
        guard let event = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let type = event["type"] as? String else { throw AppError.invalidStreamEvent }
        let response = event["response"] as? [String: Any]
        switch type {
        case "response.completed":
            guard response?["status"] as? String == "completed",
                  let messages = response?["output"] as? [[String: Any]] else { throw AppError.invalidStreamEvent }
            let content = messages.filter { $0["type"] as? String == "message" && $0["role"] as? String == "assistant" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            if content.contains(where: { $0["type"] as? String == "refusal" }) { throw AppError.refused }
            let text = content.filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AppError.emptyModelOutput }
            let usage = response?["usage"] as? [String: Any]
            let tokens = (usage?["total_tokens"] as? Int).flatMap { (0...10_000_000).contains($0) ? $0 : nil }
            final = ResponseResult(text: text, tokens: tokens)
        case "error", "response.failed":
            let fields = response?["error"] as? [String: Any] ?? event["error"] as? [String: Any] ?? event
            throw ResponseFailure(requestID: requestID, fields: fields)
        case "response.incomplete":
            throw AppError.incomplete
        default:
            break
        }
    }

    func result() throws -> ResponseResult {
        guard let final else { throw AppError.interrupted }
        return final
    }
}
