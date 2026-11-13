import CryptoKit
import Foundation
import Testing
@testable import ianautomat

@Test func oauthRejectsWrongStateAndDuplicateParameters() throws {
    let attempt = try OAuthAttempt(port: 12345, host: "urn:uuid:test", previous: nil)
    let good = "/auth/callback?client_id=oaiapp_test&code=test-code&state=\(attempt.state)"
    #expect(try attempt.parse(good)?.code == "test-code")
    #expect(try attempt.parse(good + "&state=wrong") == nil)
    #expect(try attempt.parse(good.replacingOccurrences(of: attempt.state, with: "wrong")) == nil)
    #expect(try attempt.parse(good.replacingOccurrences(of: "/auth/callback", with: "/elsewhere")) == nil)
    #expect(try attempt.parse(good.replacingOccurrences(of: "oaiapp_test", with: "dynamic_agent_client")) == nil)
    #expect(throws: AppError.self) {
        try attempt.parse("/auth/callback?error=access_denied&state=\(attempt.state)")
    }
    let query = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(query.first(where: { $0.name == "redirect_uri" })?.value == "http://127.0.0.1:12345/auth/callback")
    #expect(query.first(where: { $0.name == "code_challenge" })?.value ==
        Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64URL)
}

@Test func streamRequiresCompletionAndOnlyUsesFinalOutput() throws {
    var stream = ResponseStream()
    try stream.consume(#"{"type":"response.output_text.delta","delta":"partial"}"#)
    #expect(throws: AppError.self) { try stream.result() }
    try stream.consume(#"{"type":"response.completed","response":{"status":"completed","usage":{"total_tokens":7},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}"#)
    let result = try stream.result()
    #expect(result.text == "done")
    #expect(result.tokens == 7)
}

@Test func parseRejectsUnknownActionsAndOversizedWork() throws {
    #expect(throws: AppError.self) {
        try GoalAction.parse(#"{"action":"launch","title":"","message":"","body":"","items":[],"operation":""}"#)
    }
    #expect(throws: AppError.self) {
        try GoalAction.parse(#"{"action":"calculator","title":"My calculator","message":"","body":"","items":[],"operation":"eval"}"#)
    }
    let action = try GoalAction.parse(#"{"action":"checklist","title":"Weekend","message":"","body":"","items":["Read","Walk"],"operation":""}"#)
    #expect(action.artifact?.items == ["Read", "Walk"])
}

@Test func calculatorHandlesDivisionAndRejectsInvalidInputs() throws {
    #expect(try Calculation.divide.evaluate([12, 3, 2]) == 2)
    #expect(try Calculation.average.evaluate([2, 4]) == 3)
    #expect(throws: AppError.self) { try Calculation.divide.evaluate([3, 0]) }
    #expect(throws: AppError.self) { try Calculation.sum.evaluate([.infinity]) }
}

@Test func workspacePersistsToolsAndLogs() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    var run = GoalRun(goal: "A to-do list")
    var tool = Artifact(kind: .checklist, title: "List", items: ["A", "B"])
    tool.checked = [1]
    run.artifacts = [tool]
    run.logs = ["Saved List"]
    try workspace.save(run)
    #expect(try workspace.load() == [run])
    #expect(run.transcript.contains("Saved List"))
}

@Test(.timeLimit(.minutes(1)))
@MainActor func loopbackReceivesOneValidatedGrantOverTCP() async throws {
    let listener = try Loopback()
    defer { listener.stop() }
    let port = try await listener.listen()
    let attempt = try OAuthAttempt(port: port, host: "urn:uuid:test", previous: nil)
    var client: Task<Void, Error>?
    let grant = try await listener.awaitGrant(attempt) { _ in
        client = Task {
            do {
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForResource = 5
                let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                let invalidURL = try #require(URL(string: attempt.redirect + "?state=wrong&client_id=oaiapp_test&code=bad"))
                let (_, invalid) = try await session.data(from: invalidURL)
                #expect((invalid as? HTTPURLResponse)?.statusCode == 400)
                let validURL = try #require(URL(string: attempt.redirect + "?state=\(attempt.state)&client_id=oaiapp_test&code=good"))
                let (_, valid) = try await session.data(from: validURL)
                #expect((valid as? HTTPURLResponse)?.statusCode == 302)
                #expect((valid as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") == "ianautomat-auth://complete")
            } catch {
                listener.stop(error)
                throw error
            }
        }
    }
    #expect(grant.client == "oaiapp_test")
    #expect(grant.code == "good")
    try await client?.value
}
