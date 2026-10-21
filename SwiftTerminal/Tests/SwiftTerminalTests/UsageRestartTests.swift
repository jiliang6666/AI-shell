import Foundation
import Testing
@testable import SwiftTerminal

/// Restarts the application against the same session store and checks that the
/// turn usage and the measured context come back.
@Test("Usage and the measured context survive an app restart for the same session")
@MainActor
func usageAndContextSurviveRestart() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIRestart-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try SSEInteropServer()
    let port = try server.start()
    defer { server.stop() }

    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "重启检查", baseURL: "http://127.0.0.1:\(port)/v1",
                               model: "sse-fixture", apiKey: "fixture-not-sent",
                               contextWindow: 100_000)
    try profileStore.saveAll([profile], activeID: profile.id)
    let store = AISessionStore(directory: root.appendingPathComponent("sessions"))
    let terminalID = UUID()

    func makeModel() -> TerminalAIModel {
        let coordinator = AISessionCoordinator(store: store,
            legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
        return TerminalAIModel(terminalSessionID: terminalID, modelProfileStore: profileStore,
            sessionCoordinator: coordinator, archiveLoader: { [] }, archiveWriter: { _ in })
    }

    // First run: send a message so the provider reports usage.
    let first = makeModel()
    #expect(await first.selectModel(profile.id, sessionID: first.conversationID))
    #expect(await first.send("重启前发一条"))
    await first.waitForCurrentTurnCompletion()
    let turnID = try #require(first.messages.last?.turnID)
    let usedBefore = try #require(first.measuredContext)
    #expect(usedBefore.inputTokens > 0)
    #expect(first.usageSummary(for: turnID)?.contains("请求") == true)

    // Second run: a fresh model over the same store, like a relaunch.
    let second = makeModel()
    try await Task.sleep(for: .milliseconds(400))
    let restoredTurn = try #require(second.messages.last?.turnID)
    #expect(restoredTurn == turnID)

    let restoredUsage = second.usageSummary(for: turnID)
    print("重启前 已使用 = \(usedBefore.inputTokens) tok")
    print("重启后 用量摘要 = \(restoredUsage ?? "<nil>")")
    print("重启后 上下文实测 = \(second.measuredContext.map { "\($0.inputTokens) tok" } ?? "<nil>")")

    #expect(restoredUsage != nil)
    #expect(second.measuredContext?.inputTokens == usedBefore.inputTokens)
}

@Test("Deleting a session removes its usage and the measured context with it")
@MainActor
func deletingSessionRemovesUsageAndContext() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIDeleteUsage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try SSEInteropServer()
    let port = try server.start()
    defer { server.stop() }

    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "删除检查", baseURL: "http://127.0.0.1:\(port)/v1",
                               model: "sse-fixture", apiKey: "fixture-not-sent",
                               contextWindow: 100_000)
    try profileStore.saveAll([profile], activeID: profile.id)
    let store = AISessionStore(directory: root.appendingPathComponent("sessions"))
    let coordinator = AISessionCoordinator(store: store,
        legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    let model = TerminalAIModel(terminalSessionID: UUID(), modelProfileStore: profileStore,
        sessionCoordinator: coordinator, archiveLoader: { [] }, archiveWriter: { _ in })
    #expect(await model.selectModel(profile.id, sessionID: model.conversationID))
    #expect(await model.send("删除前发一条"))
    await model.waitForCurrentTurnCompletion()

    let sessionID = model.conversationID
    #expect(try await store.usageForSession(sessionID: sessionID).envelopes.count == 1)
    #expect(try await store.latestContextUsage(sessionID: sessionID) != nil)

    try await store.delete(sessionID: sessionID)

    #expect(try await store.usageForSession(sessionID: sessionID).envelopes.isEmpty)
    #expect(try await store.latestContextUsage(sessionID: sessionID) == nil)
}
