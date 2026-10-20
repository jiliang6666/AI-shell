import Foundation
import Testing
@testable import SwiftTerminal

@Test("Stopping a turn closes only tool calls without a result")
@MainActor
func stoppedTurnClosesOutstandingToolCalls() {
    let first = ChatToolCall(id: "first", function: ChatFunctionCall(name: "run_command", arguments: "{}"))
    let second = ChatToolCall(id: "second", function: ChatFunctionCall(name: "run_command", arguments: "{}"))
    let transcript = [
        ChatMessage(role: "assistant", toolCalls: [first, second]),
        ChatMessage(role: "tool", content: "done", toolCallID: "first")
    ]
    let results = TerminalAIModel.cancellationResults(for: transcript)
    #expect(results.map(\.toolCallID) == ["second"])
    #expect(results[0].role == "tool")
    #expect(TerminalAIModel.cancellationResults(for: transcript + results).isEmpty)
}

@Test("Tool call identifiers must be unique within one model response")
@MainActor
func duplicateToolCallIdentifiersAreRejected() {
    let first = ChatToolCall(id: "reused", function: ChatFunctionCall(name: "run_command", arguments: "{}"))
    let second = ChatToolCall(id: "reused", function: ChatFunctionCall(name: "run_saved_action", arguments: "{}"))
    let distinct = ChatToolCall(id: "other", function: ChatFunctionCall(name: "run_command", arguments: "{}"))

    #expect(!ModelAPIError.hasUniqueToolCallIDs([first, second]))
    #expect(ModelAPIError.hasUniqueToolCallIDs([first, distinct]))
}

@Test("Cancellation matches reused call identifiers to their exact request")
@MainActor
func cancellationUsesTurnRequestAndCallIdentity() {
    let turnID = UUID()
    var completedRequestCall = ChatMessage(
        role: "assistant",
        toolCalls: [ChatToolCall(id: "same", function: ChatFunctionCall(name: "run_command", arguments: "{}"))]
    )
    completedRequestCall.turnID = turnID
    completedRequestCall.requestID = UUID()

    var completedResult = ChatMessage(role: "tool", content: "done", toolCallID: "same")
    completedResult.turnID = turnID
    completedResult.requestID = completedRequestCall.requestID

    var outstandingRequestCall = ChatMessage(
        role: "assistant",
        toolCalls: [ChatToolCall(id: "same", function: ChatFunctionCall(name: "run_saved_action", arguments: "{}"))]
    )
    outstandingRequestCall.turnID = turnID
    outstandingRequestCall.requestID = UUID()

    let results = TerminalAIModel.cancellationResults(for: [
        completedRequestCall,
        completedResult,
        outstandingRequestCall
    ])

    #expect(results.count == 1)
    #expect(results.first?.toolCallID == "same")
    #expect(results.first?.requestID == outstandingRequestCall.requestID)
}
