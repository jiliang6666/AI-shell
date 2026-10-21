import Foundation

struct AIModelMenuGroup: Identifiable {
    let id: String
    let title: String
    let profiles: [ModelProfile]
}

enum AIModelMenuOptions {
    static func groups(profiles: [ModelProfile], query: String) -> [AIModelMenuGroup] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = profiles.filter { profile in
            let host = URL(string: profile.baseURL)?.host ?? "自定义服务"
            let text = "\(profile.name) \(profile.model) \(host)"
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
        let grouped = Dictionary(grouping: matching) { URL(string: $0.baseURL)?.host?.lowercased() ?? "自定义服务" }
        return grouped.keys.sorted().map { host in
            let title: String
            switch host {
            case "api.deepseek.com": title = "DeepSeek"
            case "api.openai.com": title = "OpenAI"
            default: title = host
            }
            return AIModelMenuGroup(id: host, title: title, profiles: grouped[host] ?? [])
        }
    }
}

struct AIUsagePresentation: Equatable {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    let total: String
    let compactTotal: String
    let cacheHitRate: Double?
    let rows: [Row]
    let modelRows: [Row]

    init(aggregator: AIUsageAggregator, requestCount: Int, modelRequestCounts: [String: Int]) {
        let usage = aggregator.usage
        func value(_ metric: AIMetricValue, compact: Bool = false) -> String {
            Self.metric(metric, requestCount: requestCount, reportedRequestCount: aggregator.envelopes.count, compact: compact)
        }
        total = value(usage.total)
        compactTotal = value(usage.total, compact: true)
        let providers = Set(aggregator.envelopes.map { "\($0.provider) / \($0.actualModel ?? $0.requestedModel)" }).sorted()
        let rate: String
        if aggregator.envelopes.count != requestCount || !aggregator.canComputeHitRate {
            rate = "数据不完整"
            cacheHitRate = nil
        } else if let hitRate = aggregator.cacheHitRate {
            rate = String(format: "%.1f%%", hitRate * 100)
            cacheHitRate = hitRate
        } else {
            rate = "不适用"
            cacheHitRate = nil
        }
        rows = [
            Row(label: "提供方 / 模型", value: providers.isEmpty ? "未提供" : providers.joined(separator: "\n")),
            Row(label: "缓存命中", value: rate),
            Row(label: "未缓存输入", value: value(usage.uncachedInput)),
            Row(label: "缓存读取", value: value(usage.cacheRead)),
            Row(label: "缓存写入", value: value(usage.cacheWrite)),
            Row(label: "输出", value: value(usage.output)),
            Row(label: "输入总量", value: value(usage.totalInput)),
            Row(label: "推理输出", value: value(usage.reasoning)),
            Row(label: "请求覆盖", value: "\(aggregator.envelopes.count) / \(requestCount) 次")
        ]
        let grouped = Dictionary(grouping: aggregator.envelopes, by: \.requestedModel)
        let names = Set(grouped.keys).union(modelRequestCounts.keys)
        modelRows = names.sorted().map { name in
            var group = AIUsageAggregator()
            for envelope in grouped[name] ?? [] { group.add(envelope) }
            let count = modelRequestCounts[name] ?? grouped[name]?.count ?? 0
            return Row(label: name, value: "\(count) 次 · 输入 \(Self.metric(group.usage.totalInput, requestCount: count, reportedRequestCount: group.envelopes.count)) · 输出 \(Self.metric(group.usage.output, requestCount: count, reportedRequestCount: group.envelopes.count))")
        }
    }

    static func tokens(_ value: Int64, compact: Bool = false) -> String {
        if compact && value >= 1_000_000 { return String(format: "%.1fM tok", Double(value) / 1_000_000) }
        if compact && value >= 1_000 { return String(format: "%.1fK tok", Double(value) / 1_000) }
        return value.formatted(.number.locale(Locale(identifier: "en_US"))) + " tok"
    }

    private static func metric(_ original: AIMetricValue, requestCount: Int, reportedRequestCount: Int, compact: Bool = false) -> String {
        var metric = original
        if metric.state == .known && reportedRequestCount < requestCount {
            metric.state = .partial
            metric.knownRequestCount = reportedRequestCount
        }
        switch metric.state {
        case .conflict: return "数据冲突"
        case .unknown: return "未提供"
        case .known, .partial:
            guard let value = metric.value else { return "未提供" }
            let text = tokens(value, compact: compact)
            return metric.state == .partial ? text + "（部分，\(metric.knownRequestCount)/\(requestCount)次）" : text
        }
    }
}
