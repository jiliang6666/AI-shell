import Foundation
import Testing
@testable import SwiftTerminal

@Test("DeepSeek usage maps cache fields without inventing cache writes")
func deepSeekUsageMapsDisjointFields() throws {
    let payload = UsageWire(
        promptTokens: 1000,
        completionTokens: 80,
        totalTokens: 1080,
        promptCacheHitTokens: 700,
        promptCacheMissTokens: 300
    )
    let context = AIUsageRequestContext(provider: "deepseek_chat", requestedModel: "deepseek-chat", profileID: UUID(), usageMapping: "deepseek_chat")
    let envelope = AIUsageNormalizer.decode(payload, context: context)
    #expect(envelope?.counters.totalInput.value == 1000)
    #expect(envelope?.counters.uncachedInput.value == 300)
    #expect(envelope?.counters.cacheRead.value == 700)
    #expect(envelope?.counters.cacheWrite.state == .unknown)
    #expect(envelope?.counters.output.value == 80)
    #expect(envelope?.counters.total.value == 1080)
    #expect(envelope?.completeness == .known)
}

@Test("Usage conflicts and partial data preserve other metrics")
func usageConflictsAndPartialDataAreIsolated() throws {
    let conflicting = UsageWire(
        promptTokens: 1000,
        completionTokens: 80,
        totalTokens: 1080,
        promptCacheHitTokens: 700,
        promptCacheMissTokens: 400
    )
    let context = AIUsageRequestContext(provider: "deepseek_chat", requestedModel: "test", profileID: UUID(), usageMapping: "deepseek_chat")
    let envelope = AIUsageNormalizer.decode(conflicting, context: context)
    #expect(envelope?.completeness == .conflict)
    #expect(envelope?.counters.output.value == 80)
    #expect(envelope?.counters.cacheWrite.state == .unknown)

    let partial = AIUsageNormalizer.decode(UsageWire(completionTokens: 80), context: context)
    #expect(partial?.completeness == .partial)
    #expect(partial?.counters.output.value == 80)
    #expect(partial?.counters.totalInput.value == nil)
}

@Test("Aggregated cache hit rate uses token totals and not average request rates")
func aggregateCacheHitRateUsesTotals() {
    var aggregator = AIUsageAggregator()
    let profileID = UUID()
    func envelope(requestID: UUID, prompt: Int64, read: Int64) -> AIUsageEnvelope {
        let payload = UsageWire(promptTokens: prompt, completionTokens: 1, promptCacheHitTokens: read, promptCacheMissTokens: prompt - read)
        return AIUsageNormalizer.decode(
            payload,
            context: AIUsageRequestContext(requestID: requestID, provider: "deepseek_chat", requestedModel: "test", profileID: profileID, usageMapping: "deepseek_chat")
        )!
    }
    aggregator.add(envelope(requestID: UUID(), prompt: 100, read: 90))
    aggregator.add(envelope(requestID: UUID(), prompt: 900, read: 90))
    #expect(aggregator.cacheHitRate == 0.18)
    #expect(aggregator.usage.totalInput.value == 1000)
    #expect(aggregator.usage.cacheRead.value == 180)
}

@Test("Terminal title proof is parsed only from the app marker")
func terminalTitleProofParsing() {
    let nonce = UUID().uuidString
    let proof = TerminalRunReading.completion(fromTitle: "__SWIFTTERMINAL_PROOF=\(nonce);2")
    #expect(proof == TerminalCompletionProof(nonce: nonce, exitStatus: 2))
    #expect(TerminalRunReading.completion(fromTitle: "window title") == nil)
    #expect(TerminalRunReading.completion(fromTitle: "__SWIFTTERMINAL_PROOF=nonce;bad") == nil)
}

@Test("Usage settles into SQLite and aggregates by turn and session")
func usagePersistsAndAggregates() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIUsageStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let turnID = UUID()
    func envelope(_ requestID: UUID, input: Int64, read: Int64, output: Int64) -> AIUsageEnvelope {
        let payload = UsageWire(
            promptTokens: input,
            completionTokens: output,
            totalTokens: input + output,
            promptCacheHitTokens: read,
            promptCacheMissTokens: input - read
        )
        return AIUsageNormalizer.decode(
            payload,
            context: AIUsageRequestContext(
                requestID: requestID,
                provider: "deepseek_chat",
                requestedModel: "test",
                profileID: UUID(),
                usageMapping: "deepseek_chat"
            )
        )!
    }
    let first = envelope(UUID(), input: 100, read: 90, output: 10)
    let second = envelope(UUID(), input: 900, read: 90, output: 20)
    let owner = AIRequestOwner(sessionID: session.id, turnID: turnID, maintenanceID: nil, stepIndex: 0, purpose: "conversation", attemptIndex: 0)
    try await store.settleUsage(owner: owner, envelope: first)
    try await store.settleUsage(owner: owner, envelope: second)

    let turnUsage = try await store.usageForTurn(sessionID: session.id, turnID: turnID)
    #expect(turnUsage.usage.totalInput.value == 1000)
    #expect(turnUsage.usage.output.value == 30)
    #expect(turnUsage.cacheHitRate == 0.18)
    let sessionUsage = try await store.usageForSession(sessionID: session.id)
    #expect(sessionUsage.usage.totalInput.value == 1000)
    #expect(sessionUsage.envelopes.count == 2)
}

@Test("Cumulative usage snapshots merge on one request and retain corrections")
func cumulativeUsageSnapshotsMerge() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIUsageMergeTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let turnID = UUID()
    let requestID = UUID()
    let profileID = UUID()
    func envelope(_ wire: UsageWire) -> AIUsageEnvelope {
        AIUsageNormalizer.decode(
            wire,
            context: AIUsageRequestContext(
                requestID: requestID,
                provider: "deepseek_chat",
                requestedModel: "test",
                profileID: profileID,
                usageMapping: "deepseek_chat"
            )
        )!
    }
    let owner = AIRequestOwner(sessionID: session.id, turnID: turnID, maintenanceID: nil, stepIndex: 0, purpose: "conversation", attemptIndex: 0)
    try await store.settleUsage(owner: owner, envelope: envelope(UsageWire(promptTokens: 100, promptCacheHitTokens: 70, promptCacheMissTokens: 30)))
    try await store.settleUsage(owner: owner, envelope: envelope(UsageWire(completionTokens: 12, totalTokens: 112)))

    let aggregate = try await store.usageForTurn(sessionID: session.id, turnID: turnID)
    #expect(aggregate.envelopes.count == 1)
    #expect(aggregate.envelopes[0].counters.totalInput.value == 100)
    #expect(aggregate.envelopes[0].counters.output.value == 12)
    #expect(aggregate.cacheHitRate == 0.7)
    let events = try await store.readEvents(sessionID: session.id, limit: 20)
    #expect(events.filter { $0.type == .usageCorrected }.count == 1)
}
