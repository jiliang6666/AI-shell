import Foundation
import Testing
@testable import SwiftTerminal

@Test("Context estimator v2 counts messages and non-ASCII characters")
func contextEstimatorCountsMessagesAndNonASCIICharacters() {
    let ascii = AIContextEstimator.message(ChatMessage(role: "user", content: "abc"))
    let chinese = AIContextEstimator.message(ChatMessage(role: "user", content: "中文"))
    #expect(ascii == 17)
    #expect(chinese == 19)
}

@Test("Context estimator includes tool call arguments and tool definitions")
func contextEstimatorIncludesToolPayloads() {
    let withoutCall = AIContextEstimator.message(ChatMessage(role: "assistant", content: nil))
    let withCall = AIContextEstimator.message(ChatMessage(
        role: "assistant",
        content: nil,
        toolCalls: [ChatToolCall(id: "call-1", function: ChatFunctionCall(name: "run_command", arguments: #"{"command":"df -h"}"#))]
    ))
    let tools = AIContextEstimator.tools(Data(#"{"name":"run_command"}"#.utf8))
    #expect(withCall > withoutCall)
    #expect(tools > 256)
    #expect(AIContextEstimator.version == 2)
}

@Test("Context budget uses configured reserve and fixed safety formula")
func contextBudgetUsesCapacityReserveAndSafety() {
    let configuration = AIContextConfiguration.standard
    let budget = AIContextBudgetCalculator.budget(configuration: configuration, knownCapacity: 32768)
    #expect(budget.reserve == 8192)
    #expect(budget.safety == 1639)
    #expect(budget.inputBudget == 22937)
    let unknown = AIContextBudgetCalculator.budget(configuration: configuration, knownCapacity: nil)
    #expect(unknown.inputBudget == nil)
}
