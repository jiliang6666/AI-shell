import Foundation
import Testing
@testable import SwiftTerminal

private func assistantCalling(_ ids: [String]) -> ChatMessage {
    ChatMessage(
        role: "assistant",
        content: "running",
        toolCalls: ids.map { ChatToolCall(id: $0, function: ChatFunctionCall(name: "run_inspection", arguments: "{}")) }
    )
}

private func toolResult(_ id: String, content: String = "ok") -> ChatMessage {
    ChatMessage(role: "tool", content: content, name: "run_inspection", toolCallID: id)
}

@Test("Interrupted turns get placeholder results so the history stays sendable")
func unansweredToolCallsAreFilledIn() {
    let history = [assistantCalling(["a", "b", "c"])]
    let repaired = TerminalAIModel.withAnsweredToolCalls(history)
    let toolMessages = repaired.filter { $0.role == "tool" }
    #expect(toolMessages.count == 3)
    #expect(Set(toolMessages.compactMap(\.toolCallID)) == ["a", "b", "c"])
    #expect(repaired.first?.role == "assistant")
}

@Test("Partially answered turns only get the missing results")
func partiallyAnsweredToolCallsKeepRealResults() {
    let history = [assistantCalling(["a", "b"]), toolResult("a", content: "real output")]
    let repaired = TerminalAIModel.withAnsweredToolCalls(history)
    let toolMessages = repaired.filter { $0.role == "tool" }
    #expect(toolMessages.count == 2)
    #expect(toolMessages.contains { $0.toolCallID == "a" && $0.content == "real output" })
    #expect(toolMessages.contains { $0.toolCallID == "b" })
}

@Test("Fully answered turns are left untouched, including a follow-up user turn")
func answeredToolCallsAreUnchanged() {
    let history = [
        assistantCalling(["a"]),
        toolResult("a"),
        ChatMessage(role: "user", content: "next"),
        ChatMessage(role: "assistant", content: "done")
    ]
    let repaired = TerminalAIModel.withAnsweredToolCalls(history)
    #expect(repaired.count == history.count)
    #expect(repaired.map(\.role) == ["assistant", "tool", "user", "assistant"])
}

@Test("A summarised-away result is replaced, not silently dropped")
func summarisedResultIsReplaced() {
    // Compaction can remove the tool message while the assistant tool_calls
    // message stays, which produced the same provider rejection.
    let history = [assistantCalling(["a", "b"]), toolResult("a")]
    let repaired = TerminalAIModel.withAnsweredToolCalls(history)
    #expect(repaired.compactMap(\.toolCallID).filter { $0 == "b" }.count == 1)
}
