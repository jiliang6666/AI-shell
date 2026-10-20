import Foundation

enum AICommandStatus: String, Codable, Sendable {
    case completed, failed, timedOut, unknown, information

    var title: String {
        switch self {
        case .completed: "已完成"
        case .failed: "未成功"
        case .timedOut: "已超时"
        case .unknown: "状态待确认"
        case .information: "说明"
        }
    }

    var notice: String? {
        switch self {
        case .failed: "命令执行失败。"
        case .timedOut: "命令执行超时。"
        case .unknown: "命令完成状态未确认。"
        case .completed, .information: nil
        }
    }
}

/// Local transcript metadata. It is never encoded in the provider's chat request.
struct AICommandResultMetadata: Codable, Equatable, Sendable {
    var status: AICommandStatus
    var command: String?
    var purpose: String?
    var omittedBytes: Int64 = 0

    init(result: ShellCommandResult, proposal: ProposedShellCommand) {
        status = result.timedOut ? .timedOut : (result.exitCodeUnknown ? .unknown : (result.exitCode == 0 ? .completed : .failed))
        command = proposal.command
        purpose = proposal.purpose
        omittedBytes = result.omittedBytes
    }

    init(status: AICommandStatus, command: String? = nil, purpose: String? = nil, omittedBytes: Int64 = 0) {
        self.status = status
        self.command = command
        self.purpose = purpose
        self.omittedBytes = omittedBytes
    }
}

struct AICommandResultPresentation {
    var status: AICommandStatus
    var output: String
    var command: String?
    var purpose: String?
    var isPartial: Bool

    init(message: ChatMessage, descriptor: AITranscriptCommandDescriptor? = nil) {
        let parsed = Self.envelope(message.content ?? "")
        status = message.commandResult?.status ?? parsed.status
        output = parsed.output
        command = message.commandResult?.command ?? descriptor?.command
        purpose = message.commandResult?.purpose ?? descriptor?.purpose
        isPartial = (message.commandResult?.omittedBytes ?? 0) > 0
    }

    // Saved transcripts from older versions have no local metadata. Only parse
    // the application's exact envelope; leave arbitrary command output intact.
    private static func envelope(_ content: String) -> (status: AICommandStatus, output: String) {
        guard let separator = content.range(of: "\n\n") else { return (.information, content) }
        let header = content[..<separator.lowerBound].split(separator: "\n")
        guard header.count == 2, header[0].hasPrefix("退出码"), header[1].hasPrefix("采集范围") else {
            return (.information, content)
        }
        let status: AICommandStatus
        if header[0].contains("执行超时") || header[0].contains("超过 180 秒") { status = .timedOut }
        else if header[0].contains("未知") { status = .unknown }
        else { status = header[0] == "退出码：0" ? .completed : .failed }
        return (status, String(content[separator.upperBound...]))
    }

    static func content(_ content: String) -> String {
        let parsed = envelope(content)
        if let notice = parsed.status.notice { return parsed.output.isEmpty ? notice : "\(notice)\n\n\(parsed.output)" }
        return parsed.output.isEmpty && parsed.status == .completed ? "命令已完成。" : parsed.output
    }
}

struct AITranscriptCommandDescriptor: Equatable {
    var command: String?
    var purpose: String
}

struct AIChatMessageRow: Identifiable {
    var message: ChatMessage
    var descriptor: AITranscriptCommandDescriptor?
    var result: AICommandResultPresentation? = nil
    var id: UUID { message.id }
}

struct AIChatTranscriptPresentation {
    private struct CallKey: Hashable {
        var turnID: UUID?
        var requestID: UUID?
        var callID: String
    }

    private struct CachedCalls {
        var source: [ChatToolCall]
        var descriptors: [(String, AITranscriptCommandDescriptor)]
    }

    private struct CachedResult {
        var content: String?
        var metadata: AICommandResultMetadata?
        var descriptor: AITranscriptCommandDescriptor?
        var presentation: AICommandResultPresentation
    }

    private var firstMessageID: UUID?
    private var callCache: [UUID: CachedCalls] = [:]
    private var resultCache: [UUID: CachedResult] = [:]

    static func rows(_ messages: [ChatMessage]) -> [AIChatMessageRow] {
        var projection = Self()
        return projection.project(messages)
    }

    /// Reuse decoded calls and output strings while the current answer streams.
    /// Association uses turn/request/call identity so provider IDs can be reused.
    mutating func project(_ messages: [ChatMessage]) -> [AIChatMessageRow] {
        if firstMessageID != messages.first?.id {
            callCache.removeAll(keepingCapacity: true)
            resultCache.removeAll(keepingCapacity: true)
            firstMessageID = messages.first?.id
        }
        var calls: [CallKey: AITranscriptCommandDescriptor] = [:]
        var rows: [AIChatMessageRow] = []
        rows.reserveCapacity(messages.count)
        for message in messages {
            if let source = message.toolCalls, !source.isEmpty {
                let cached: CachedCalls
                if let existing = callCache[message.id], existing.source == source { cached = existing }
                else {
                    cached = CachedCalls(source: source, descriptors: source.compactMap { call in
                        Self.descriptor(call).map { (call.id, $0) }
                    })
                    callCache[message.id] = cached
                }
                for (id, descriptor) in cached.descriptors {
                    calls[CallKey(turnID: message.turnID, requestID: message.requestID, callID: id)] = descriptor
                }
            }
            let descriptor = message.toolCallID.flatMap { calls[CallKey(turnID: message.turnID, requestID: message.requestID, callID: $0)] }
            var row = AIChatMessageRow(message: message, descriptor: descriptor)
            if message.role == "tool", message.name != "ask_user" {
                if let existing = resultCache[message.id], existing.content == message.content,
                   existing.metadata == message.commandResult, existing.descriptor == descriptor {
                    row.result = existing.presentation
                } else {
                    let presentation = AICommandResultPresentation(message: message, descriptor: descriptor)
                    resultCache[message.id] = CachedResult(content: message.content, metadata: message.commandResult,
                        descriptor: descriptor, presentation: presentation)
                    row.result = presentation
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func descriptor(_ call: ChatToolCall) -> AITranscriptCommandDescriptor? {
        guard let data = call.function.arguments.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch call.function.name {
        case "run_command":
            return AITranscriptCommandDescriptor(command: arguments["command"] as? String, purpose: arguments["purpose"] as? String ?? "执行命令")
        case "inspect_target", "run_inspection":
            let operation = arguments["operation"] as? String ?? "system"
            let names = ["system": "检查系统环境", "disk": "检查磁盘", "docker": "检查 Docker", "services": "检查服务", "sdkman": "检查 SDKMAN"]
            return AITranscriptCommandDescriptor(command: LocalShellCommandRunner.inspectionCommand(operation), purpose: names[operation] ?? "检查环境")
        case "run_saved_action": return AITranscriptCommandDescriptor(command: nil, purpose: "运行已保存操作")
        default: return nil
        }
    }
}

/// Wording for the banner that stops an AI turn when a command result could
/// not be confirmed.
///
/// The cause matters. A command that was interrupted for a known reason (a
/// password prompt, a stalled command) leaves a usable terminal behind, so
/// sending the user to "check the bound terminal" points at a problem that is
/// not there. Only a genuinely unverified terminal keeps that wording.
enum AICommandPausePresentation {
    static func message(for result: ShellCommandResult) -> String {
        let reason = result.interruptedNotice?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reason.isEmpty else {
            return "命令完成状态未知，本轮已暂停。请检查绑定终端后再继续。"
        }
        let recovery: String
        switch result.terminalReturnedToPrompt {
        case .some(true):
            recovery = "绑定终端已确认可用，命令没有留在前台；处理后回复「继续」即可接着做。"
        case .some(false):
            recovery = "绑定终端可能仍在运行或已断开，请检查后再继续。"
        case .none:
            recovery = "确认现场状态后回复「继续」即可接着做。"
        }
        return "命令已中断，本轮已暂停。\n原因：\(reason)\n\(recovery)"
    }
}
