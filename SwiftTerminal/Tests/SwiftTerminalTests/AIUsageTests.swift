import Foundation
import Testing
@testable import SwiftTerminal

@Test("DeepSeek usage maps cache fields and derives the cache write from the miss total")
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
    #expect(envelope?.counters.cacheRead.source == .provider)
    // DeepSeek reports no write counter: the miss total is what the request
    // wrote into the disk cache, so it is recorded as a derived value.
    #expect(envelope?.counters.cacheWrite.value == 300)
    #expect(envelope?.counters.cacheWrite.source == .derived)
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
    // The provider's own cache totals do not add up, so the derived write
    // cannot be trusted either.
    #expect(envelope?.counters.cacheWrite.state == .conflict)

    let partial = AIUsageNormalizer.decode(UsageWire(completionTokens: 80), context: context)
    #expect(partial?.completeness == .partial)
    #expect(partial?.counters.output.value == 80)
    #expect(partial?.counters.totalInput.value == nil)
}

@Test("A gateway that reports no cache at all keeps every cache field unknown")
func gatewayWithoutCacheInformationKeepsCacheFieldsUnknown() throws {
    let context = AIUsageRequestContext(provider: "openai_compatible", requestedModel: "gpt", profileID: UUID(), usageMapping: "openai_compatible")
    let envelope = AIUsageNormalizer.decode(
        UsageWire(promptTokens: 1000, completionTokens: 80, totalTokens: 1080),
        context: context
    )
    #expect(envelope?.counters.cacheRead.state == .unknown)
    #expect(envelope?.counters.cacheWrite.state == .unknown)
    #expect(envelope?.counters.uncachedInput.state == .unknown)
}

@Test("Gateway cache fields are read from either the OpenAI or the Anthropic shape")
func gatewayCacheFieldsAreMapped() throws {
    let context = AIUsageRequestContext(provider: "openai_compatible", requestedModel: "gateway", profileID: UUID(), usageMapping: "openai_compatible")
    // Anthropic style: the cached read arrives at the top level.
    let anthropicStyle = AIUsageNormalizer.decode(
        UsageWire(promptTokens: 1000, completionTokens: 80, totalTokens: 1080, cacheReadInputTokens: 600),
        context: context
    )
    #expect(anthropicStyle?.counters.cacheRead.value == 600)
    #expect(anthropicStyle?.counters.uncachedInput.value == 400)

    // OpenAI style with a write counter reported next to the cached read.
    let openAIJSON = """
    {"prompt_tokens":1000,"completion_tokens":80,"total_tokens":1080,\
    "prompt_tokens_details":{"cached_tokens":250,"cache_write_tokens":750}}
    """
    let openAI = AIUsageNormalizer.decode(
        try JSONDecoder().decode(UsageWire.self, from: Data(openAIJSON.utf8)), context: context
    )
    #expect(openAI?.counters.cacheRead.value == 250)
    #expect(openAI?.counters.cacheWrite.value == 750)
    #expect(openAI?.counters.cacheWrite.source == .provider)
    #expect(openAI?.counters.uncachedInput.value == 750)
}

@Test("A gateway without a write counter derives it from the uncached remainder")
func gatewayCacheWriteIsDerivedFromUncachedRemainder() throws {
    let context = AIUsageRequestContext(provider: "openai_compatible", requestedModel: "gateway", profileID: UUID(), usageMapping: "openai_compatible")
    let json = """
    {"prompt_tokens":4000,"completion_tokens":120,"total_tokens":4120,\
    "prompt_tokens_details":{"cached_tokens":3200}}
    """
    let envelope = AIUsageNormalizer.decode(
        try JSONDecoder().decode(UsageWire.self, from: Data(json.utf8)), context: context
    )
    #expect(envelope?.counters.cacheRead.value == 3200)
    #expect(envelope?.counters.uncachedInput.value == 800)
    // The tokens that missed the cache were computed and then persisted.
    #expect(envelope?.counters.cacheWrite.value == 800)
    #expect(envelope?.counters.cacheWrite.source == .derived)
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
