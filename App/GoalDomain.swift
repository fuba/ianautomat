import Foundation

enum AppError: LocalizedError, Equatable {
    case security
    case denied
    case signedOut
    case missingPlan
    case noModels
    case badResponse
    case interrupted
    case incomplete
    case refused
    case unexpectedContentType
    case invalidStreamEvent
    case emptyModelOutput
    case busy
    case invalidTool
    case invalidNumbers
    case storage
    case listener
    case timedOut
    case http(Int)
    case usageLimit

    var errorDescription: String? {
        switch self {
        case .security: String(localized: "ChatGPT sign-in could not be verified.")
        case .denied: String(localized: "ChatGPT sign-in was declined.")
        case .signedOut: String(localized: "Connect your ChatGPT account first.")
        case .missingPlan: String(localized: "This account did not grant ChatGPT plan usage.")
        case .noModels: String(localized: "No models are available for this account.")
        case .badResponse: String(localized: "The server returned an invalid response.")
        case .interrupted: String(localized: "The response stream was interrupted.")
        case .incomplete: String(localized: "The model response did not finish.")
        case .refused: String(localized: "The model declined to complete this goal.")
        case .unexpectedContentType: String(localized: "OpenAI did not return a response stream.")
        case .invalidStreamEvent: String(localized: "The response stream contained an invalid event.")
        case .emptyModelOutput: String(localized: "The model completed without returning an action.")
        case .busy: String(localized: "Another connection operation is in progress.")
        case .invalidTool: String(localized: "The model returned an unsupported action or tool.")
        case .invalidNumbers: String(localized: "Enter valid numbers and avoid dividing by zero.")
        case .storage: String(localized: "Could not read or write local data.")
        case .listener: String(localized: "Could not start the local sign-in listener.")
        case .timedOut: String(localized: "ChatGPT sign-in timed out.")
        case .http(let code): String(localized: "OpenAI returned HTTP \(code).")
        case .usageLimit: String(localized: "ChatGPT plan usage is unavailable or has reached its limit.")
        }
    }

    var retryable: Bool {
        switch self {
        case .http(let code): [408, 429, 500, 502, 503, 504].contains(code)
        case .interrupted: true
        default: false
        }
    }
}

enum Calculation: String, Codable, CaseIterable {
    case sum, subtract, multiply, divide, average, minimum, maximum

    var title: String {
        switch self {
        case .sum: String(localized: "Sum")
        case .subtract: String(localized: "Subtract")
        case .multiply: String(localized: "Multiply")
        case .divide: String(localized: "Divide")
        case .average: String(localized: "Average")
        case .minimum: String(localized: "Minimum")
        case .maximum: String(localized: "Maximum")
        }
    }

    func evaluate(_ values: [Double]) throws -> Double {
        guard let first = values.first, values.count <= 100, values.allSatisfy(\.isFinite) else {
            throw AppError.invalidNumbers
        }
        let remaining = values.dropFirst()
        let result: Double
        switch self {
        case .sum: result = values.reduce(0, +)
        case .subtract: result = remaining.reduce(first, -)
        case .multiply: result = remaining.reduce(first, *)
        case .divide:
            guard !remaining.contains(0) else { throw AppError.invalidNumbers }
            result = remaining.reduce(first, /)
        case .average: result = values.reduce(0) { $0 + $1 / Double(values.count) }
        case .minimum: result = values.min() ?? first
        case .maximum: result = values.max() ?? first
        }
        guard result.isFinite else { throw AppError.invalidNumbers }
        return result
    }
}

struct Artifact: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case note, checklist, calculator

        var title: String {
            switch self {
            case .note: String(localized: "Note")
            case .checklist: String(localized: "Checklist")
            case .calculator: String(localized: "Calculator")
            }
        }

        var icon: String {
            switch self {
            case .note: "doc.text"
            case .checklist: "checklist"
            case .calculator: "plus.forwardslash.minus"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var body = ""
    var items: [String] = []
    var operation: Calculation?
    var checked: Set<Int> = []

    var exportText: String {
        let rows = items.enumerated().map { index, item in
            "\(checked.contains(index) ? "☑" : "☐") \(item)"
        }
        return ([title, body, operation?.title ?? ""] + rows)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct GoalAction: Decodable {
    enum Kind: String, Decodable { case note, checklist, calculator, done, blocked }

    let action: Kind
    let title: String
    let message: String
    let body: String
    let items: [String]
    let operation: String

    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 80_000,
              let result = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              result.title.count <= 100, result.message.count <= 2_000,
              result.body.utf8.count <= 32_000,
              result.items.count <= 40,
              result.items.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500 }),
              result.operation.utf8.count <= 16 else { throw AppError.invalidTool }
        switch result.action {
        case .done, .blocked:
            guard !result.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.invalidTool
            }
        case .note, .checklist, .calculator:
            guard !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result.artifact != nil else { throw AppError.invalidTool }
        }
        return result
    }

    var artifact: Artifact? {
        switch action {
        case .note where !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            Artifact(kind: .note, title: title, body: body)
        case .checklist where !items.isEmpty:
            Artifact(kind: .checklist, title: title, body: body, items: items)
        case .calculator:
            Calculation(rawValue: operation).map {
                Artifact(kind: .calculator, title: title, body: body, operation: $0)
            }
        default: nil
        }
    }
}

struct GoalRun: Codable, Identifiable, Equatable {
    enum Phase: String, Codable {
        case running, paused, limited, stopped, completed, blocked

        var resumable: Bool { self == .paused || self == .limited }
        var active: Bool { self == .running || resumable }

        var title: String {
            switch self {
            case .running: String(localized: "Running")
            case .paused: String(localized: "Paused")
            case .limited: String(localized: "Step limit reached")
            case .stopped: String(localized: "Stopped")
            case .completed: String(localized: "Completed")
            case .blocked: String(localized: "Blocked")
            }
        }
    }

    var id = UUID()
    var date = Date()
    var goal: String
    var phase: Phase = .running
    var steps = 0
    var tokens = 0
    var artifacts: [Artifact] = []
    var logs: [String] = []

    var transcript: String {
        ([goal, phase.title, String(localized: "Steps \(steps) · Tokens \(tokens)")] + logs)
            .joined(separator: "\n")
    }
}

struct Workspace {
    let directory: URL

    static let local = Workspace(
        directory: URL.applicationSupportDirectory.appending(path: "Goals", directoryHint: .isDirectory)
    )

    func save(_ run: GoalRun) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: run.id.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(run).write(to: path, options: [.atomic, .completeFileProtection])
    }

    func load() throws -> [GoalRun] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(GoalRun.self, from: Data(contentsOf: $0))
        }.sorted { $0.date > $1.date }
    }
}
