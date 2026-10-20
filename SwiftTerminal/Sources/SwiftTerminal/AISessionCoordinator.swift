import Foundation
import SwiftUI

@MainActor
final class AISessionCoordinator: ObservableObject {
    static let shared = AISessionCoordinator()

    let store: AISessionStore
    private let legacyArchiveURL: URL?
    private let resumeExecutionHistory: @MainActor () throws -> Void

    init(
        store: AISessionStore = AISessionStore(),
        legacyArchiveURL: URL? = nil,
        resumeExecutionHistory: @escaping @MainActor () throws -> Void = { try ExecutionHistoryStore.resumeTerminalDeletions() }
    ) {
        self.store = store
        self.legacyArchiveURL = legacyArchiveURL
        self.resumeExecutionHistory = resumeExecutionHistory
    }
    @Published private(set) var records: [ConversationRecord] = []
    @Published private(set) var didBootstrap = false
    @Published private(set) var bootstrapErrorMessage: String?
    @Published private(set) var permissionPreferences: [AIPermissionScope: AIPermissionPreference] = [:]
    private var bootstrapTask: Task<Void, Never>?

    func bootstrap() async {
        if didBootstrap { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        bootstrapErrorMessage = nil
        do {
            try await store.resumeTerminalCleanup()
            try resumeExecutionHistory()
            if FileManager.default.fileExists(atPath: archiveFile.path) {
                _ = try await store.migrateLegacyArchive(sourceURL: archiveFile)
            }
            let preferences = try await store.permissionPreferences()
            permissionPreferences = preferences.mapValues { AIPermissionPreference(mode: $0) }
            try await store.deleteUnassignedHistory()
        } catch {
            bootstrapErrorMessage = error.localizedDescription
            NSLog("SwiftTerminal: AI session bootstrap failed: %@ \(String(describing: error))")
        }
        do {
            _ = try await store.recoverInterruptedSessions()
        } catch {
            bootstrapErrorMessage = bootstrapErrorMessage ?? error.localizedDescription
            NSLog("SwiftTerminal: AI session recovery failed: %@ \(String(describing: error))")
        }
        await refresh()
        didBootstrap = true
        bootstrapTask = nil
    }

    func ensureSession(id: UUID, target: AITargetSnapshot, profileID: UUID?) async -> AISessionSnapshot? {
        do {
            if let existing = try? await store.load(sessionID: id) {
                guard existing.target.terminalSessionID == target.terminalSessionID else { return nil }
                return existing
            }
            return try await store.create(sessionID: id, target: target, modelProfileID: profileID,
                permission: permissionPreferences[AIPermissionScope(hostID: target.hostID)]?.mode ?? .readOnly)
        } catch {
            await setPersistentError(error)
            return nil
        }
    }

    func latest(terminalID: UUID) async -> AISessionSnapshot? {
        do {
            let summaries = try await store.list(filter: .terminal(terminalID), limit: 1)
            guard let id = summaries.first?.id else { return nil }
            return try await store.load(sessionID: id)
        } catch {
            await setPersistentError(error)
            return nil
        }
    }

    func load(id: UUID) async -> AISessionSnapshot? {
        (try? await store.load(sessionID: id)) ?? nil
    }

    func listForTerminal(_ terminalID: UUID) async throws -> [AISessionSummary] {
        var all: [AISessionSummary] = []
        while all.count < 300 {
            let count = min(50, 300 - all.count)
            let page = try await store.list(filter: .terminal(terminalID), limit: count, offset: all.count)
            all += page
            if page.count < count { break }
        }
        return all
    }

    @discardableResult
    func sync(_ snapshot: ConversationRecord) async -> Bool {
        let target = AITargetSnapshot(hostID: snapshot.targetHostID, terminalSessionID: snapshot.terminalSessionID, workingDirectory: nil, displayName: snapshot.targetName)
        guard await ensureSession(id: snapshot.id, target: target, profileID: nil) != nil else { return false }
        for _ in 0..<3 {
            guard let session = try? await store.load(sessionID: snapshot.id) else { return false }
            let persisted = Dictionary(uniqueKeysWithValues: session.messages.map { ($0.id, AIStoredMessage(message: $0)) })
            let events = snapshot.messages.compactMap { message -> AINewSessionEvent? in
                let stored = AIStoredMessage(message: message)
                guard persisted[message.id] != stored else { return nil }
                if persisted[message.id] != nil, message.role == "user" { return nil }
                let payload: AISessionEventPayload
                let type: AISessionEventType
                switch message.role {
                case "user":
                    payload = .userMessage(messageID: message.id, content: message.content ?? "")
                    type = .userMessage
                case "assistant":
                    payload = .assistantMessage(messageID: message.id, stored: stored)
                    type = .assistantMessage
                default:
                    payload = .legacyMessage(messageID: message.id, stored: stored)
                    type = .migrationImported
                }
                return AINewSessionEvent(sessionID: snapshot.id, type: type, turnID: message.turnID, requestID: message.requestID, payload: payload.data)
            }
            guard !events.isEmpty else { return true }
            do {
                _ = try await store.append(events, expectedRevision: session.revision)
                await refresh()
                return true
            } catch AISessionStoreError.staleRevision {
                continue
            } catch {
                await setPersistentError(error)
                return false
            }
        }
        return false
    }

    func setPermission(sessionID: UUID, new: AIPermissionMode) async throws {
        let session = try await store.load(sessionID: sessionID)
        let scope = AIPermissionScope(hostID: session.target.hostID)
        let old = permissionPreferences[scope] ?? AIPermissionPreference()
        guard !old.isSaving else { throw AISessionStoreError.invalidArguments }
        guard old.mode != new || old.persistenceFailed else { return }
        let downgrade = AIPermissionMode.allCases.firstIndex(of: new)! < AIPermissionMode.allCases.firstIndex(of: old.mode)!
        var pending = old
        pending.isSaving = true
        pending.errorMessage = nil
        if downgrade { pending.mode = new; pending.version += 1 }
        permissionPreferences[scope] = pending
        do {
            try await appendMutation(sessionID: sessionID, type: .permissionChanged,
                payload: AISessionEventPayload.permissionChanged(old: old.mode, new: new).data,
                permissionPreference: (scope, new))
            var saved = pending
            if saved.mode != new { saved.mode = new; saved.version += 1 }
            saved.isSaving = false
            saved.persistenceFailed = false
            permissionPreferences[scope] = saved
        } catch {
            var failed = downgrade ? pending : old
            failed.isSaving = false
            failed.persistenceFailed = downgrade || old.persistenceFailed
            failed.errorMessage = "权限保存失败：\(error.localizedDescription)"
            permissionPreferences[scope] = failed
            throw error
        }
    }

    func selectModel(sessionID: UUID, profileID: UUID, contextWindow: Int64?) async throws {
        try await appendMutation(
            sessionID: sessionID,
            type: .modelSelected,
            payload: AISessionEventPayload.modelSelected(profileID: profileID, contextWindow: contextWindow).data
        )
    }

    func configureContext(sessionID: UUID, profileID: UUID, configuration: AIContextConfiguration) async throws {
        try await appendMutation(
            sessionID: sessionID,
            type: .profileContextConfigured,
            payload: AISessionEventPayload.profileContextConfigured(profileID: profileID, configuration: configuration).data
        )
    }

    func endTurn(sessionID: UUID, turnID: UUID, status: String, errorCode: AIErrorCode? = nil) async throws {
        try await appendMutation(
            sessionID: sessionID,
            type: .turnEnded,
            payload: AISessionEventPayload.turnEnded(turnID: turnID, status: status, errorCode: errorCode).data,
            turnID: turnID
        )
    }

    func recordToolIntent(
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        callID: String,
        command: String,
        context: AIExecutionContext
    ) async throws {
        let payload = AIToolIntentEventPayload(
            callID: callID,
            commandDigest: AISessionIdentity.digest(Data(command.utf8)),
            target: context.target,
            permissionVersion: context.permissionVersion
        )
        try await appendMutation(
            sessionID: sessionID,
            type: .toolIntent,
            payload: (try? JSONEncoder().encode(payload)) ?? Data(),
            turnID: turnID,
            requestID: requestID
        )
    }

    func recordToolResult(
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        payload: AIToolResultEventPayload
    ) async throws {
        try await appendMutation(
            sessionID: sessionID,
            type: .toolResult,
            payload: (try? JSONEncoder().encode(payload)) ?? Data(),
            turnID: turnID,
            requestID: requestID
        )
    }

    private func appendMutation(
        sessionID: UUID,
        type: AISessionEventType,
        payload: Data,
        turnID: UUID? = nil,
        requestID: UUID? = nil,
        permissionPreference: (scope: AIPermissionScope, mode: AIPermissionMode)? = nil
    ) async throws {
        var lastError: Error = AISessionStoreError.staleRevision
        for _ in 0..<3 {
            let session = try await store.load(sessionID: sessionID)
            do {
                _ = try await store.append(
                    [AINewSessionEvent(sessionID: sessionID, type: type, turnID: turnID, requestID: requestID, payload: payload)],
                    expectedRevision: session.revision, permissionPreference: permissionPreference
                )
                await refresh()
                return
            } catch AISessionStoreError.staleRevision {
                lastError = AISessionStoreError.staleRevision
            } catch {
                lastError = error
                break
            }
        }
        await setPersistentError(lastError)
        throw lastError
    }

    func settleUsage(_ envelope: AIUsageEnvelope?, owner: AIRequestOwner) async {
        do {
            try await store.settleUsage(owner: owner, envelope: envelope)
        } catch {
            await setPersistentError(error)
        }
    }

    func startRequest(requestID: UUID, owner: AIRequestOwner, model: AIModelSnapshot, requestBody: Data) async throws {
        try await store.startRequest(owner: owner, requestID: requestID, model: model, requestBody: requestBody)
        await refresh()
    }

    func finishRequest(requestID: UUID, owner: AIRequestOwner, status: String) async throws {
        try await store.finishRequest(owner: owner, requestID: requestID, status: status)
        await refresh()
    }

    func deleteTerminalHistory(terminalID: UUID) async throws {
        await bootstrap()
        guard bootstrapErrorMessage == nil else { throw AISessionStoreError.persistenceFailed(bootstrapErrorMessage ?? "存储未准备好") }
        try await store.deleteTerminalHistory(terminalID: terminalID)
        records.removeAll { $0.terminalSessionID == terminalID }
        await refresh()
    }

    func delete(id: UUID) async {
        try? await store.delete(sessionID: id)
        await refresh()
    }

    func clearAll() async {
        try? await store.clearAll()
        await refresh()
    }

    func pruneExpired() async {
        _ = try? await store.pruneExpired(retentionDays: AppPreferences.load().historyRetentionDays)
        await refresh()
    }

    func refresh() async {
        do {
            var summaries: [AISessionSummary] = []
            while summaries.count < 300 {
                let limit = min(50, 300 - summaries.count)
                let page = try await store.list(limit: limit, offset: summaries.count)
                summaries += page
                if page.count < limit { break }
            }
            var result: [ConversationRecord] = []
            for summary in summaries {
                result.append(ConversationRecord(
                    id: summary.id,
                    targetHostID: summary.targetHostID,
                    targetName: summary.targetName,
                    title: summary.title,
                    messages: [],
                    updatedAt: summary.updatedAt,
                    terminalSessionID: summary.terminalSessionID
                ))
            }
            records = result
            NotificationCenter.default.post(name: .conversationArchiveChanged, object: nil)
        } catch {
            await setPersistentError(error)
        }
    }

    private var archiveFile: URL {
        legacyArchiveURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftTerminal/conversations.json")
    }

    private func setPersistentError(_ error: Error) async {
        NSLog("SwiftTerminal: AI session store error: %@", String(describing: error))
    }
}
