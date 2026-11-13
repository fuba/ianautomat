import Foundation
import Testing
@testable import ianautomat

private let completed = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"初霜や"}]}]}}"#

private func parse(_ input: String) throws -> ResponseResult {
    var stream = ResponseStream()
    for byte in input.utf8 {
        try stream.receive(byte)
        if stream.completed { break }
    }
    return try stream.result()
}

@Test func streamDispatchesSeparateFramesAndPreservesJapaneseText() throws {
    for newline in ["\n", "\r\n", "\r"] {
        let lines = [
            "\u{FEFF}: keep-alive", "",
            "event: response.created", #"data: {"type":"response.created"}"#, "",
            "event: response.completed", "data: " + completed, "", ""
        ]
        let result = try parse(lines.joined(separator: newline))
        #expect(result.text == "初霜や")
        #expect(result.tokens == nil)
    }
}

@Test func streamJoinsDataLinesAndDiscardsAnUnterminatedEvent() throws {
    let line = completed.replacingOccurrences(of: ",\"response\"", with: ",\ndata: \"response\"")
    #expect(try parse("data: " + line + "\n\n").text == "初霜や")
    #expect(throws: AppError.interrupted) { try parse("data: " + completed + "\n") }
    #expect(throws: AppError.interrupted) {
        try parse(#"data: {"type":"response.output_text.delta","delta":"partial"}"# + "\n\n")
    }
}

@Test func streamDistinguishesIncompleteRefusedAndRejectedRequests() throws {
    #expect(throws: AppError.incomplete) {
        try parse(#"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"# + "\n\n")
    }
    #expect(throws: AppError.refused) {
        try parse(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"Private text"}]}]}}"# + "\n\n")
    }
    let rejected = #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"text.format","message":"Private response text"}}"#
    let error = ResponseFailure(status: 400, requestID: "req_example", body: Data(rejected.utf8))
    #expect(error.code == "subscription_sharing_unsupported_capability")
    #expect(error.parameter == "text.format")
    #expect(error.localizedDescription.contains("req_example"))
    #expect(!error.localizedDescription.contains("Private response text"))
    #expect(!error.retryable)
}
