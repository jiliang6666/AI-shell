import Foundation
import Testing
@testable import SwiftTerminal

@Test("Context estimator v3 is calibrated against measured provider token counts")
func contextEstimatorCountsMessagesAndNonASCIICharacters() {
    // The provider tokenizes Chinese at roughly 0.91 tokens per character and
    // ASCII at roughly 0.38. The previous guess of 1.5 per Chinese character
    // over-counted this app's Chinese prompts by about 1.7 times, which made
    // automatic compaction fire while a third of the window was still free.
    #expect(AIContextEstimator.text(String(repeating: "中", count: 100)) == 91)
    #expect(AIContextEstimator.text(String(repeating: "a", count: 100)) == 38)
    #expect(AIContextEstimator.message(ChatMessage(role: "user", content: "abc")) == 18)
    #expect(AIContextEstimator.message(ChatMessage(role: "user", content: "中文")) == 18)
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
    #expect(AIContextEstimator.version == 3)
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

@Test("Context reporting exposes the measured window use, its share and the compaction threshold")
@MainActor
func contextReportingExposesMeasuredUseAndThreshold() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIContextReporting-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "上下文", baseURL: "https://api.deepseek.com/v1",
                                model: "deepseek-flash", apiKey: "fixture-not-sent",
                                contextWindow: 1_000_000)
    try profileStore.saveAll([profile], activeID: profile.id)
    let coordinator = AISessionCoordinator(
        store: AISessionStore(directory: root.appendingPathComponent("sessions")),
        legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    let model = TerminalAIModel(terminalSessionID: UUID(), modelProfileStore: profileStore,
        sessionCoordinator: coordinator, archiveLoader: { [] }, archiveWriter: { _ in })
    #expect(await model.selectModel(profile.id, sessionID: model.conversationID))

    // Capacity 1,000,000: 8,192 output reserve, 50,000 safety, 941,808 input.
    #expect(model.contextBudget.capacity == 1_000_000)
    #expect(model.contextBudget.inputBudget == 941_808)
    #expect(model.contextThresholdTokens == 753_447)
    // No request has run yet, so the measured window use is still unknown.
    #expect(model.measuredContext == nil)
    #expect(model.measuredContextShare == nil)
}
