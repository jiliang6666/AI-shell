import CryptoKit
import Foundation

enum AIPermissionMode: String, Codable, CaseIterable, Sendable {
    case readOnly = "read_only"
    case terminalOnly = "terminal_only"
    case fullAccess = "full_access"

    var title: String {
        switch self {
        case .readOnly: "仅可查看"
        case .terminalOnly: "在终端内运行"
        case .fullAccess: "完全权限"
        }
    }

    var symbol: String {
        switch self {
        case .readOnly: "eye"
        case .terminalOnly: "terminal"
        case .fullAccess: "shield.lefthalf.filled"
        }
    }
}

/// Shared independently of terminal, host, and conversation lifetime.
enum AIPermissionScope: String, CaseIterable, Sendable {
    case local, ssh
    init(hostID: UUID?) { self = hostID == nil ? .local : .ssh }
}

struct AIPermissionPreference: Equatable, Sendable {
    var mode: AIPermissionMode = .readOnly
    var version: Int64 = 1
    var isSaving = false
    var persistenceFailed = false
    var errorMessage: String?
}

enum AIToolAction: String, Codable, Sendable {
    case fixedInspection = "fixed_inspection"
    case metadataRead = "metadata_read"
    case arbitraryShell = "arbitrary_shell"
    case savedShell = "saved_shell"
    case nativeMutation = "native_mutation"
}

enum AIExecutionBackend: String, Codable, Sendable {
    case restrictedInspection = "restricted_inspection"
    case terminal
    case background
    case native
}

enum AICompletionState: String, Codable, Sendable {
    case completed, unknown, waitingForInput = "waiting_for_input"
    case timedOut = "timed_out", cancelled, unavailable, denied, skipped
}

enum AIToolCaptureScope: String, Codable, Sendable {
    case processPipe = "process_pipe"
    case renderedTerminalBuffer = "rendered_terminal_buffer"
    case applicationResult = "application_result"
    case unknown
}

struct AITargetSnapshot: Codable, Equatable, Sendable {
    var hostID: UUID?
    var terminalSessionID: UUID?
    var workingDirectory: String?
    var displayName: String

    static func local(workingDirectory: String?) -> AITargetSnapshot {
        AITargetSnapshot(hostID: nil, terminalSessionID: nil, workingDirectory: workingDirectory, displayName: "本机")
    }
}

struct AIContextConfiguration: Codable, Equatable, Sendable {
    var contextWindowOverride: Int64?
    var outputReserve: Int64?
    var autoCompact: Bool
    var triggerRatio: Double
    var keepRecentTurns: Int
    var safetyRatio: Double
    var minimumSafetyTokens: Int64
    var summaryMaxOutputTokens: Int64

    static let standard = AIContextConfiguration(
        contextWindowOverride: nil,
        outputReserve: nil,
        autoCompact: true,
        triggerRatio: 0.8,
        keepRecentTurns: 4,
        safetyRatio: 0.05,
        minimumSafetyTokens: 512,
        summaryMaxOutputTokens: 2048
    )

    func validated(contextWindow: Int64?) throws -> Int64? {
        guard (0.5...0.95).contains(triggerRatio), (1...20).contains(keepRecentTurns),
              (256...4096).contains(summaryMaxOutputTokens), minimumSafetyTokens == 512,
              safetyRatio == 0.05 else {
            throw AISessionStoreError.invalidArguments
        }
        if let override = contextWindowOverride, !(1024...2_097_152).contains(override) {
            throw AISessionStoreError.invalidArguments
        }
        guard let capacity = contextWindowOverride ?? contextWindow else { return nil }
        let reserve = outputReserve ?? min(8192, capacity / 4)
        let safety = max(minimumSafetyTokens, Int64((Double(capacity) * safetyRatio).rounded(.up)))
        guard reserve >= 1, reserve <= capacity - safety - 1 else { throw AISessionStoreError.invalidArguments }
        return capacity - reserve - safety
    }
}

struct AIModelSnapshot: Codable, Equatable, Sendable {
    var profileID: UUID
    var configurationRevision: Int64
    var endpoint: URL
    var provider: String
    var requestedModel: String
    var contextWindow: Int64?
    var maxOutputTokens: Int64?
    var usageMapping: String
    var streamUsageSupport: String

    var frozenWithoutCredentials: AIModelSnapshot { self }
}

struct AIStoredMessage: Codable, Equatable, Sendable {
    var id: UUID
    var role: String
    var content: String?
    var name: String?
    var toolCallID: String?
    var toolCallsJSON: Data?
    var commandResult: AICommandResultMetadata?

    init(message: ChatMessage) {
        id = message.id
        role = message.role
        content = message.content
        name = message.name
        toolCallID = message.toolCallID
        commandResult = message.commandResult
        if let toolCalls = message.toolCalls {
            toolCallsJSON = try? JSONEncoder().encode(toolCalls)
        }
    }

    var message: ChatMessage {
        var result = ChatMessage(id: id, role: role, content: content)
        result.name = name
        result.toolCallID = toolCallID
        result.commandResult = commandResult
        if let toolCallsJSON,
           let toolCalls = try? JSONDecoder().decode([ChatToolCall].self, from: toolCallsJSON) {
            result.toolCalls = toolCalls
        }
        return result
    }
}

struct AIToolIntentEventPayload: Codable, Sendable {
    var callID: String
    var commandDigest: String
    var target: AITargetSnapshot
    var permissionVersion: Int64
}

struct AIToolResultEventPayload: Codable, Sendable {
    var callID: String
    var messageID: UUID
    var name: String
    var content: String
    var completion: AICompletionState
    var exitCode: Int32?
    var backend: AIExecutionBackend
    var capturedOutput: String?
    var capturedBytes: Int64
    var omittedBytes: Int64
    var captureScope: AIToolCaptureScope
    var commandResult: AICommandResultMetadata?

    private enum CodingKeys: String, CodingKey {
        case callID, messageID, name, content, completion, exitCode, backend
        case capturedOutput, capturedBytes, omittedBytes, captureScope
        case commandResult
    }

    init(
        callID: String,
        messageID: UUID,
        name: String,
        content: String,
        completion: AICompletionState,
        exitCode: Int32?,
        backend: AIExecutionBackend,
        capturedOutput: String? = nil,
        capturedBytes: Int64 = 0,
        omittedBytes: Int64 = 0,
        captureScope: AIToolCaptureScope = .unknown,
        commandResult: AICommandResultMetadata? = nil
    ) {
        self.callID = callID
        self.messageID = messageID
        self.name = name
        self.content = content
        self.completion = completion
        self.exitCode = exitCode
        self.backend = backend
        self.capturedOutput = capturedOutput
        self.capturedBytes = capturedBytes
        self.omittedBytes = omittedBytes
        self.captureScope = captureScope
        self.commandResult = commandResult
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        callID = try values.decode(String.self, forKey: .callID)
        messageID = try values.decode(UUID.self, forKey: .messageID)
        name = try values.decode(String.self, forKey: .name)
        content = try values.decode(String.self, forKey: .content)
        completion = try values.decode(AICompletionState.self, forKey: .completion)
        exitCode = try values.decodeIfPresent(Int32.self, forKey: .exitCode)
        backend = try values.decode(AIExecutionBackend.self, forKey: .backend)
        capturedOutput = try values.decodeIfPresent(String.self, forKey: .capturedOutput)
        capturedBytes = try values.decodeIfPresent(Int64.self, forKey: .capturedBytes) ?? 0
        omittedBytes = try values.decodeIfPresent(Int64.self, forKey: .omittedBytes) ?? 0
        captureScope = try values.decodeIfPresent(AIToolCaptureScope.self, forKey: .captureScope) ?? .unknown
        commandResult = try values.decodeIfPresent(AICommandResultMetadata.self, forKey: .commandResult)
    }
}

enum AISessionEventType: String, Codable, CaseIterable, Sendable {
    case sessionCreated = "session_created"
    case turnStarted = "turn_started"
    case userMessage = "user_message"
    case requestStarted = "request_started"
    case requestSettled = "request_settled"
    case usageCorrected = "usage_corrected"
    case assistantMessage = "assistant_message"
    case toolIntent = "tool_intent"
    case toolResult = "tool_result"
    case permissionChanged = "permission_changed"
    case modelSelected = "model_selected"
    case contextConfigured = "context_configured"
    case profileContextConfigured = "profile_context_configured"
    case contextProjected = "context_projected"
    case compactionStarted = "compaction_started"
    case compactionCommitted = "compaction_committed"
    case compactionEnded = "compaction_ended"
    case turnEnded = "turn_ended"
    case migrationImported = "migration_imported"

    var advancesModelContext: Bool {
        switch self {
        case .userMessage, .assistantMessage, .toolResult, .modelSelected, .contextConfigured, .profileContextConfigured, .contextProjected:
            true
        default: false
        }
    }
}

struct AINewSessionEvent: Codable, Sendable {
    var eventID = UUID()
    var sessionID: UUID
    var type: AISessionEventType
    var turnID: UUID?
    var requestID: UUID?
    var payload: Data
    var payloadVersion = 1
}

struct AISessionEvent: Codable, Identifiable, Sendable {
    var eventID: UUID
    var sessionID: UUID
    var sequence: Int64
    var timestamp: Date
    var type: AISessionEventType
    var turnID: UUID?
    var requestID: UUID?
    var payload: Data
    var payloadVersion: Int

    var id: UUID { eventID }
}

struct AIAppendReceipt: Equatable, Sendable {
    var revision: Int64
    var contextRevision: Int64
    var eventIDs: [UUID]
    var firstSequence: Int64
    var lastSequence: Int64
    var deduplicated: Bool
}

struct AISessionSnapshot: Codable, Sendable {
    var id: UUID
    var target: AITargetSnapshot
    var permission: AIPermissionMode
    var permissionVersion: Int64
    var modelProfileID: UUID?
    var configuration: AIContextConfiguration
    var revision: Int64
    var contextRevision: Int64
    var messages: [ChatMessage]
    var turnStates: [UUID: String]
    var summaryIDs: [UUID]
    var contextSummary: String?
    var summarizedMessageIDs: Set<UUID>
    var parentSessionID: UUID?
    var forkSequence: Int64?
}

struct AIContextProjectionPayload: Codable, Sendable {
    var compactionID: UUID
    var summary: String
    var sourceMessageIDs: [String]

    var summarizedMessageIDs: Set<UUID> {
        Set(sourceMessageIDs.compactMap(UUID.init(uuidString:)))
    }
}

struct AISessionSummary: Codable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var targetHostID: UUID?
    var targetName: String
    var updatedAt: Date
    var permission: AIPermissionMode
    var modelProfileID: UUID?
    var terminalSessionID: UUID? = nil

    var idValue: UUID { id }
}

enum AISessionFilter: Equatable, Sendable {
    case all
    case local
    case host(UUID)
    case terminal(UUID)

    var hostID: UUID? {
        if case .host(let id) = self { return id }
        return nil
    }
}

struct AIRecoveryReport: Equatable, Sendable {
    var sessionIDs: [UUID]
    var interruptedTurnIDs: [UUID]
    var unknownCallKeys: [String]
    var discardedCompactionIDs: [UUID]
}

struct AIMigrationReport: Equatable, Sendable {
    var importedSessions: Int
    var importedEvents: Int
    var skippedSessions: Int
    var backupPath: String
    var completed: Bool
    var errorCodes: [AIErrorCode]
}

enum AIErrorCode: String, Codable, Error, LocalizedError, Sendable {
    case permissionDenied = "permission_denied"
    case targetMismatch = "target_mismatch"
    case terminalUnavailable = "terminal_unavailable"
    case terminalBusy = "terminal_busy"
    case completionUnknown = "completion_unknown"
    case authenticationRequired = "authentication_required"
    case busy
    case cancelled
    case invalidArguments = "invalid_arguments"
    case unknownCommand = "unknown_command"
    case modelMissing = "model_missing"
    case modelRequestFailed = "model_request_failed"
    case capacityUnknown = "capacity_unknown"
    case contextOverflow = "context_overflow"
    case noCompactableHistory = "no_compactable_history"
    case summaryFailed = "summary_failed"
    case staleRevision = "stale_revision"
    case persistenceFailed = "persistence_failed"
    case migrationFailed = "migration_failed"
    case usageConflict = "usage_conflict"
    case sessionMissing = "session_missing"
    case unsupportedSchema = "unsupported_schema"
    case legacySourceChanged = "legacy_source_changed"
    case resourceLimit = "resource_limit"
    case deadlineExceeded = "deadline_exceeded"

    var errorDescription: String? {
        "AI 操作失败：\(rawValue)"
    }
}

enum AISessionEventPayload: Codable, Sendable {
    case sessionCreated(target: AITargetSnapshot, permission: AIPermissionMode, profileID: UUID?)
    case turnStarted(turnID: UUID, target: AITargetSnapshot, model: AIModelSnapshot)
    case userMessage(messageID: UUID, content: String)
    case assistantMessage(messageID: UUID, stored: AIStoredMessage)
    case legacyMessage(messageID: UUID, stored: AIStoredMessage)
    case turnEnded(turnID: UUID, status: String, errorCode: AIErrorCode?)
    case permissionChanged(old: AIPermissionMode, new: AIPermissionMode)
    case modelSelected(profileID: UUID, contextWindow: Int64?)
    case contextConfigured(configuration: AIContextConfiguration)
    case profileContextConfigured(profileID: UUID, configuration: AIContextConfiguration)
    case migrationImported(sourceRecordID: UUID, sourceDigest: String, legacyBoundary: Bool)
    case requestStarted(owner: AIRequestOwner, model: AIModelSnapshot)
    case requestSettled(owner: AIRequestOwner, usage: AIUsageEnvelope?, status: String, errorCode: AIErrorCode?)

    var data: Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }
}

enum AISessionStoreError: Equatable, Error, LocalizedError, Sendable {
    case busy
    case invalidArguments
    case sessionMissing
    case staleRevision
    case persistenceFailed(String)
    case migrationFailed(String)
    case legacySourceChanged
    case unsupportedSchema

    var errorDescription: String? {
        switch self {
        case .busy: "AI 会话正在运行，暂时不能删除或清空。"
        case .invalidArguments: "AI 会话参数无效。"
        case .sessionMissing: "AI 会话不存在。"
        case .staleRevision: "AI 会话已被其他操作更新。"
        case .persistenceFailed(let detail): "AI 会话保存失败：\(detail)"
        case .migrationFailed(let detail): "旧 AI 会话迁移失败：\(detail)"
        case .legacySourceChanged: "旧 AI 会话源文件在迁移后发生了变化。"
        case .unsupportedSchema: "AI 会话数据库版本不受支持。"
        }
    }
}

enum AISessionIdentity {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func stableMessageID(sessionID: UUID, index: Int, content: Data) -> UUID {
        var seed = Data()
        seed.append(contentsOf: sessionID.uuidString.utf8)
        seed.append(UInt8(index & 0xff))
        seed.append(UInt8((index >> 8) & 0xff))
        seed.append(contentsOf: content)
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
