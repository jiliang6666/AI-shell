import Foundation

enum AIMetricState: String, Codable, Equatable, Sendable {
    case known, unknown, partial, conflict
}

enum AIMetricSource: String, Codable, Equatable, Sendable {
    case provider, derived, unavailable
}

struct AIMetricValue: Codable, Equatable, Sendable {
    var value: Int64?
    var state: AIMetricState
    var source: AIMetricSource
    var knownRequestCount = 0
    var requestCount = 0

    static let unknown = AIMetricValue(value: nil, state: .unknown, source: .unavailable)
}

struct AITokenUsage: Codable, Equatable, Sendable {
    var totalInput = AIMetricValue.unknown
    var uncachedInput = AIMetricValue.unknown
    var cacheRead = AIMetricValue.unknown
    var cacheWrite = AIMetricValue.unknown
    var output = AIMetricValue.unknown
    var total = AIMetricValue.unknown
    var reasoning = AIMetricValue.unknown

    static let empty = AITokenUsage()
}

struct UsageWire: Decodable, Equatable, Sendable {
    var promptTokens: Int64?
    var completionTokens: Int64?
    var totalTokens: Int64?
    var promptCacheHitTokens: Int64?
    var promptCacheMissTokens: Int64?
    var cachedTokens: Int64?
    var cacheReadInputTokens: Int64?
    var cacheWriteTokens: Int64?
    var reasoningTokens: Int64?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case promptCacheMissTokens = "prompt_cache_miss_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    init(
        promptTokens: Int64? = nil,
        completionTokens: Int64? = nil,
        totalTokens: Int64? = nil,
        promptCacheHitTokens: Int64? = nil,
        promptCacheMissTokens: Int64? = nil,
        cachedTokens: Int64? = nil,
        cacheReadInputTokens: Int64? = nil,
        cacheWriteTokens: Int64? = nil,
        reasoningTokens: Int64? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptCacheHitTokens = promptCacheHitTokens
        self.promptCacheMissTokens = promptCacheMissTokens
        self.cachedTokens = cachedTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try values.decodeIfPresent(Int64.self, forKey: .promptTokens)
        completionTokens = try values.decodeIfPresent(Int64.self, forKey: .completionTokens)
        totalTokens = try values.decodeIfPresent(Int64.self, forKey: .totalTokens)
        promptCacheHitTokens = try values.decodeIfPresent(Int64.self, forKey: .promptCacheHitTokens)
        promptCacheMissTokens = try values.decodeIfPresent(Int64.self, forKey: .promptCacheMissTokens)
        cacheReadInputTokens = try values.decodeIfPresent(Int64.self, forKey: .cacheReadInputTokens)
        if let details = try? values.nestedContainer(keyedBy: DetailKeys.self, forKey: .promptTokensDetails) {
            cachedTokens = try details.decodeIfPresent(Int64.self, forKey: .cachedTokens)
            cacheWriteTokens = try details.decodeIfPresent(Int64.self, forKey: .cacheWriteTokens)
        }
        if let details = try? values.nestedContainer(keyedBy: DetailKeys.self, forKey: .completionTokensDetails) {
            reasoningTokens = try details.decodeIfPresent(Int64.self, forKey: .reasoningTokens)
        }
    }

    private enum DetailKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case reasoningTokens = "reasoning_tokens"
    }
}

struct AIUsageEnvelope: Codable, Equatable, Sendable {
    var requestID: UUID
    var providerResponseID: String?
    var provider: String
    var requestedModel: String
    var actualModel: String?
    var profileID: UUID
    var counters: AITokenUsage
    var completeness: AIMetricState
    var canComputeHitRate: Bool
}

struct AIRequestOwner: Codable, Equatable, Sendable {
    var sessionID: UUID
    var turnID: UUID?
    var maintenanceID: UUID?
    var stepIndex: Int?
    var purpose: String
    var attemptIndex: Int

    static let conversationPurpose = "conversation"

    /// Compaction posts its own summarisation prompt with no tools, so it
    /// shares no prefix with the conversation. Counting it would report a
    /// permanently uncacheable request inside the conversation's hit rate.
    var isConversation: Bool { purpose == Self.conversationPurpose }
}

struct AIUsageRequestContext: Sendable {
    var requestID = UUID()
    var providerResponseID: String?
    var actualModel: String? = nil
    var provider: String
    var requestedModel: String
    var profileID: UUID
    var usageMapping: String
}

/// The context size a provider actually billed for a request. It is the
/// authoritative measure of how full the window is, while the estimator only
/// predicts what the next request will cost.
struct AIContextMeasurement: Equatable, Sendable {
    var inputTokens: Int64
    var cachedTokens: Int64
}

enum AIUsageNormalizer {
    static func metric(_ value: Int64?) -> AIMetricValue {
        guard let value else { return .unknown }
        guard value >= 0 else { return conflict(nil) }
        return AIMetricValue(value: value, state: .known, source: .provider)
    }

    /// A value the provider does not report directly but that follows from the
    /// numbers it does report. It is kept apart from provider-reported metrics
    /// so the interface can label it as an estimate instead of a fact.
    static func derived(_ value: Int64?) -> AIMetricValue {
        guard let value else { return .unknown }
        guard value >= 0 else { return conflict(nil) }
        return AIMetricValue(value: value, state: .known, source: .derived)
    }

    static func conflict(_ value: Int64?) -> AIMetricValue {
        AIMetricValue(value: value, state: .conflict, source: .provider)
    }

    static func decode(_ payload: UsageWire, context: AIUsageRequestContext) -> AIUsageEnvelope? {
        let counters = counters(for: payload, mapping: context.usageMapping)
        let anyKnown = [counters.totalInput, counters.output, counters.total].contains { $0.state != .unknown }
        guard anyKnown else { return nil }
        let conflicted = [
            counters.totalInput, counters.uncachedInput, counters.cacheRead,
            counters.cacheWrite, counters.output, counters.total, counters.reasoning
        ].contains { $0.state == .conflict }
        let completeness: AIMetricState = conflicted
            ? .conflict
            : ((counters.totalInput.state == .known && counters.output.state == .known) ? .known : .partial)
        let canComputeHitRate = counters.totalInput.state == .known && counters.cacheRead.state == .known
        return AIUsageEnvelope(
            requestID: context.requestID,
            providerResponseID: context.providerResponseID,
            provider: context.provider,
            requestedModel: context.requestedModel,
            actualModel: context.actualModel,
            profileID: context.profileID,
            counters: counters,
            completeness: completeness,
            canComputeHitRate: canComputeHitRate
        )
    }

    private static func counters(for usage: UsageWire, mapping: String) -> AITokenUsage {
        var result = AITokenUsage()
        result.output = metric(usage.completionTokens)
        result.total = metric(usage.totalTokens)
        result.reasoning = metric(usage.reasoningTokens)
        if let input = usage.promptTokens, let output = usage.completionTokens, let total = usage.totalTokens,
           input >= 0, output >= 0, total >= 0 {
            let (sum, overflow) = input.addingReportingOverflow(output)
            if overflow || sum != total { result.total = conflict(total) }
        }
        switch mapping {
        case "deepseek_chat":
            let readFields = [usage.promptCacheHitTokens, usage.cachedTokens].compactMap { $0 }
            let readValue: Int64?
            if readFields.contains(where: { $0 < 0 }) || Set(readFields).count > 1 {
                result.cacheRead = conflict(usage.promptCacheHitTokens ?? usage.cachedTokens)
            } else {
                readValue = readFields.first
                result.cacheRead = metric(readValue)
            }
            result.uncachedInput = metric(usage.promptCacheMissTokens)
            // DeepSeek reports no separate write counter. Every prompt token
            // that missed the cache was computed and then persisted for later
            // requests, so the miss total is what this request wrote into the
            // disk cache.
            result.cacheWrite = derived(usage.promptCacheMissTokens)
            result.totalInput = metric(usage.promptTokens)
            if let prompt = usage.promptTokens, let hit = usage.promptCacheHitTokens, let miss = usage.promptCacheMissTokens,
               prompt >= 0, hit >= 0, miss >= 0 {
                let (sum, overflow) = hit.addingReportingOverflow(miss)
                if overflow || sum != prompt {
                    result.totalInput = conflict(prompt)
                    result.cacheRead = conflict(hit)
                    result.uncachedInput = conflict(miss)
                    result.cacheWrite = conflict(nil)
                }
            }
        case "openai_compatible":
            result.totalInput = metric(usage.promptTokens)
            // Gateways that keep a prompt cache report the cached read either
            // in `prompt_tokens_details.cached_tokens` or in the Anthropic
            // style `cache_read_input_tokens`.
            let readFields = [usage.cachedTokens, usage.cacheReadInputTokens].compactMap { $0 }
            if readFields.contains(where: { $0 < 0 }) || Set(readFields).count > 1 {
                result.cacheRead = conflict(readFields.first)
            } else {
                result.cacheRead = metric(readFields.first)
            }
            if let write = usage.cacheWriteTokens {
                result.cacheWrite = metric(write)
            } else if let prompt = usage.promptTokens, let cached = readFields.first,
                      prompt >= 0, cached >= 0, prompt >= cached {
                // No write counter: the tokens that missed the cache were
                // computed and then persisted, so the uncached remainder is
                // what this request wrote into the cache.
                result.cacheWrite = derived(prompt - cached)
            }
            if let prompt = usage.promptTokens, let cached = readFields.first,
               prompt >= 0, cached >= 0, prompt >= cached {
                result.uncachedInput = metric(prompt - cached)
            } else if usage.promptTokens != nil, !readFields.isEmpty {
                result.uncachedInput = conflict(nil)
            }
        default:
            break
        }
        return result
    }
}

enum AIUsageSnapshotMerger {
    static func merge(earlier: AIUsageEnvelope?, later: AIUsageEnvelope) -> AIUsageEnvelope {
        guard let earlier else { return later }
        guard earlier.requestID == later.requestID else { return later }
        let counters = AITokenUsage(
            totalInput: merge(earlier.counters.totalInput, later.counters.totalInput),
            uncachedInput: merge(earlier.counters.uncachedInput, later.counters.uncachedInput),
            cacheRead: merge(earlier.counters.cacheRead, later.counters.cacheRead),
            cacheWrite: merge(earlier.counters.cacheWrite, later.counters.cacheWrite),
            output: merge(earlier.counters.output, later.counters.output),
            total: merge(earlier.counters.total, later.counters.total),
            reasoning: merge(earlier.counters.reasoning, later.counters.reasoning)
        )
        let values = [counters.totalInput, counters.uncachedInput, counters.cacheRead, counters.cacheWrite, counters.output, counters.total, counters.reasoning]
        let completeness: AIMetricState = values.contains(where: { $0.state == .conflict })
            ? .conflict
            : (counters.totalInput.state == .known && counters.output.state == .known ? .known : .partial)
        return AIUsageEnvelope(
            requestID: later.requestID,
            providerResponseID: later.providerResponseID ?? earlier.providerResponseID,
            provider: later.provider,
            requestedModel: later.requestedModel,
            actualModel: later.actualModel ?? earlier.actualModel,
            profileID: later.profileID,
            counters: counters,
            completeness: completeness,
            canComputeHitRate: counters.totalInput.state == .known && counters.cacheRead.state == .known
        )
    }

    private static func merge(_ earlier: AIMetricValue, _ later: AIMetricValue) -> AIMetricValue {
        if earlier.state == .conflict || later.state == .conflict {
            return AIMetricValue(value: nil, state: .conflict, source: later.source)
        }
        if later.state == .unknown || later.value == nil {
            return earlier
        }
        return later
    }
}

struct AIUsageAggregator {
    private(set) var usage = AITokenUsage.empty
    private(set) var envelopes: [AIUsageEnvelope] = []
    private(set) var canComputeHitRate = true

    mutating func add(_ envelope: AIUsageEnvelope) {
        if let index = envelopes.firstIndex(where: { $0.requestID == envelope.requestID }) {
            envelopes[index] = envelope
            var merged = AITokenUsage.empty
            canComputeHitRate = true
            for item in envelopes {
                merged = AITokenUsage(
                    totalInput: merge(merged.totalInput, item.counters.totalInput),
                    uncachedInput: merge(merged.uncachedInput, item.counters.uncachedInput),
                    cacheRead: merge(merged.cacheRead, item.counters.cacheRead),
                    cacheWrite: merge(merged.cacheWrite, item.counters.cacheWrite),
                    output: merge(merged.output, item.counters.output),
                    total: merge(merged.total, item.counters.total),
                    reasoning: merge(merged.reasoning, item.counters.reasoning)
                )
                canComputeHitRate = canComputeHitRate && item.canComputeHitRate
            }
            usage = merged
            return
        } else {
            envelopes.append(envelope)
            usage = AITokenUsage(
                totalInput: merge(usage.totalInput, envelope.counters.totalInput),
                uncachedInput: merge(usage.uncachedInput, envelope.counters.uncachedInput),
                cacheRead: merge(usage.cacheRead, envelope.counters.cacheRead),
                cacheWrite: merge(usage.cacheWrite, envelope.counters.cacheWrite),
                output: merge(usage.output, envelope.counters.output),
                total: merge(usage.total, envelope.counters.total),
                reasoning: merge(usage.reasoning, envelope.counters.reasoning)
            )
            canComputeHitRate = canComputeHitRate && envelope.canComputeHitRate
        }
    }

    var cacheHitRate: Double? {
        guard canComputeHitRate, !envelopes.isEmpty,
              let input = usage.totalInput.value, input > 0,
              let read = usage.cacheRead.value, read >= 0, read <= input else { return nil }
        return Double(read) / Double(input)
    }

    private func merge(_ current: AIMetricValue, _ next: AIMetricValue) -> AIMetricValue {
        var result = next
        let (requestCount, requestCountOverflow) = current.requestCount.addingReportingOverflow(1)
        let (knownRequestCount, knownCountOverflow) = current.knownRequestCount.addingReportingOverflow(next.state == .known ? 1 : 0)
        result.requestCount = requestCountOverflow ? Int.max : requestCount
        result.knownRequestCount = knownCountOverflow ? Int.max : knownRequestCount
        if next.state == .conflict || current.state == .conflict {
            result.state = .conflict
            result.value = nil
        } else if let currentValue = current.value, let nextValue = next.value {
            let (sum, overflow) = currentValue.addingReportingOverflow(nextValue)
            if overflow {
                result.state = .conflict
                result.value = nil
            } else {
                result.value = sum
                result.state = current.state == .known && next.state == .known ? .known : .partial
            }
        } else if let nextValue = next.value {
            result.value = nextValue
            result.state = current.requestCount == 0 && next.state == .known ? .known : .partial
        } else if let currentValue = current.value {
            result.value = currentValue
            result.state = .partial
        } else {
            result.value = nil
            result.state = current.state == .partial || next.state == .partial ? .partial : .unknown
        }
        return result
    }
}

struct AIUsageAggregate: Equatable, Sendable {
    var usage: AITokenUsage
    var envelopes: [AIUsageEnvelope]
    var cacheHitRate: Double?
    var requestCount: Int
    var modelRequestCounts: [String: Int]
}
