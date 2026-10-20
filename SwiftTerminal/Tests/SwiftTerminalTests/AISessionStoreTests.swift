import Foundation
import Testing
@testable import SwiftTerminal

private func makeLegacyFile(in directory: URL, isoDates: Bool = true) throws -> URL {
    let message = ChatMessage(role: "user", content: "检查磁盘")
    let reply = ChatMessage(role: "assistant", content: "磁盘空间充足。")
    let record = ConversationRecord(
        id: UUID(),
        targetHostID: nil,
        targetName: "本机",
        title: message.content ?? "旧对话",
        messages: [message, reply],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let encoder = JSONEncoder()
    if isoDates { encoder.dateEncodingStrategy = .iso8601 }
    let file = directory.appendingPathComponent("conversations.json")
    try encoder.encode([record]).write(to: file, options: .atomic)
    return file
}

private struct StartedPayload: Codable {
    var compactionID: UUID
    var sourceContextRevision: Int64
}

private struct CommittedPayload: Codable {
    var compactionID: UUID
    var summary: String
    var sourceMessageIDs: [String]
}

@Test("AI session store persists events with transactional sequence and deduplicates identical batches")
func aiSessionStoreAppendIsTransactionalAndIdempotent() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AISessionStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let target = AITargetSnapshot.local(workingDirectory: "/tmp")
    let session = try await store.create(target: target, modelProfileID: nil)

    let messageID = UUID()
    let event = AINewSessionEvent(
        sessionID: session.id,
        type: .userMessage,
        payload: AISessionEventPayload.userMessage(messageID: messageID, content: "检查磁盘").data
    )
    let receipt = try await store.append([event], expectedRevision: session.revision)
    #expect(receipt.revision == 2)
    #expect(receipt.contextRevision == 1)
    #expect(receipt.firstSequence == 2)
    #expect(!receipt.deduplicated)

    let duplicate = try await store.append([event], expectedRevision: 99)
    #expect(duplicate.revision == 2)
    #expect(duplicate.deduplicated)

    await #expect(throws: AISessionStoreError.staleRevision) {
        try await store.append([event, AINewSessionEvent(
            sessionID: session.id,
            type: .userMessage,
            payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "混合批次").data
        )], expectedRevision: receipt.revision)
    }

    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.messages.count == 1)
    #expect(loaded.messages[0].id == messageID)
    #expect(loaded.messages[0].content == "检查磁盘")

    let events = try await store.readEvents(sessionID: session.id)
    #expect(events.map(\.sequence) == [1, 2])

    let local = try await store.list(filter: .local)
    #expect(local.count == 1)
    #expect(local[0].targetHostID == nil)
}

@Test("Legacy conversations migrate once with stable message IDs and preserve readable history", arguments: [true, false])
func legacyArchiveMigrationIsIdempotent(_ isoDates: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeLegacyFile(in: directory, isoDates: isoDates)
    let store = AISessionStore(directory: directory)

    let first = try await store.migrateLegacyArchive(sourceURL: source)
    #expect(first.importedSessions == 1)
    #expect(first.importedEvents == 4)
    #expect(first.completed)
    #expect(FileManager.default.fileExists(atPath: first.backupPath))

    let second = try await store.migrateLegacyArchive(sourceURL: source)
    #expect(second.importedSessions == 0)
    #expect(second.importedEvents == 0)

    let sessions = try await store.list()
    #expect(sessions.count == 1)
    let loaded = try await store.load(sessionID: sessions[0].id)
    #expect(loaded.permission == .readOnly)
    #expect(loaded.messages.map(\.role) == ["user", "assistant"])
    #expect(loaded.messages.map(\.content) == ["检查磁盘", "磁盘空间充足。"])
}

@Test("Session projection updates a streamed assistant message without duplicating it")
func sessionProjectionUpsertsStreamedAssistantMessage() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIMessageProjectionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let messageID = UUID()
    let turnID = UUID()
    let partial = ChatMessage(id: messageID, role: "assistant", content: "partial")
    let final = ChatMessage(id: messageID, role: "assistant", content: "complete")
    let first = AINewSessionEvent(
        sessionID: session.id,
        type: .assistantMessage,
        turnID: turnID,
        payload: AISessionEventPayload.assistantMessage(messageID: messageID, stored: AIStoredMessage(message: partial)).data
    )
    let firstReceipt = try await store.append([first], expectedRevision: session.revision)
    let update = AINewSessionEvent(
        sessionID: session.id,
        type: .assistantMessage,
        turnID: turnID,
        payload: AISessionEventPayload.assistantMessage(messageID: messageID, stored: AIStoredMessage(message: final)).data
    )
    _ = try await store.append([update], expectedRevision: firstReceipt.revision)

    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.messages.count == 1)
    #expect(loaded.messages[0].content == "complete")
    #expect(loaded.messages[0].turnID == turnID)
}

@Test("A settled tool result restores its transcript without replaying the call")
func settledToolResultRestoresTranscript() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIToolResultProjectionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let turnID = UUID()
    let requestID = UUID()
    let callID = "call-\(UUID().uuidString)"
    let messageID = UUID()
    let intent = AINewSessionEvent(
        sessionID: session.id,
        type: .toolIntent,
        turnID: turnID,
        requestID: requestID,
        payload: try JSONEncoder().encode(AIToolIntentEventPayload(callID: callID, commandDigest: "digest", target: session.target, permissionVersion: 1))
    )
    let result = AINewSessionEvent(
        sessionID: session.id,
        type: .toolResult,
        turnID: turnID,
        requestID: requestID,
        payload: try JSONEncoder().encode(AIToolResultEventPayload(
            callID: callID,
            messageID: messageID,
            name: "run_command",
            content: "退出码：0\n\nready",
            completion: .completed,
            exitCode: 0,
            backend: .terminal
        ))
    )
    _ = try await store.append([intent, result], expectedRevision: session.revision)

    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.messages.count == 1)
    #expect(loaded.messages[0].id == messageID)
    #expect(loaded.messages[0].role == "tool")
    #expect(loaded.messages[0].toolCallID == callID)
    #expect(loaded.messages[0].turnID == turnID)
    #expect(try await store.recoverInterruptedSessions().unknownCallKeys.isEmpty)
}

@Test("Legacy tool result events decode without capture counters")
func legacyToolResultEventDecodesWithoutCaptureCounters() throws {
    let messageID = UUID()
    let legacy = try JSONSerialization.data(withJSONObject: [
        "callID": "legacy-call",
        "messageID": messageID.uuidString,
        "name": "run_command",
        "content": "ready",
        "completion": "completed",
        "exitCode": 0,
        "backend": "terminal"
    ])
    let decoded = try JSONDecoder().decode(AIToolResultEventPayload.self, from: legacy)
    #expect(decoded.content == "ready")
    #expect(decoded.capturedOutput == nil)
    #expect(decoded.capturedBytes == 0)
    #expect(decoded.omittedBytes == 0)
}

@Test("Legacy archive changes after migration are rejected without reimport")
func changedLegacyArchiveIsRejected() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIChangedMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeLegacyFile(in: directory)
    let store = AISessionStore(directory: directory)
    _ = try await store.migrateLegacyArchive(sourceURL: source)

    let updated = try Data(contentsOf: source) + Data([0x20])
    try updated.write(to: source, options: .atomic)
    await #expect(throws: AISessionStoreError.legacySourceChanged) {
        try await store.migrateLegacyArchive(sourceURL: source)
    }
    #expect(try await store.list().count == 1)
}

@Test("Open turns and unmatched tool intents are recovered without replay")
func recoveryMarksOpenTurnsAndUnknownTools() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let turnID = UUID()
    let requestID = UUID()
    let laterRequestID = UUID()
    let intentID = "call-\(UUID().uuidString)"
    let started = AINewSessionEvent(
        sessionID: session.id,
        type: .turnStarted,
        turnID: turnID,
        payload: AISessionEventPayload.turnStarted(
            turnID: turnID,
            target: session.target,
            model: AIModelSnapshot(
                profileID: UUID(),
                configurationRevision: 1,
                endpoint: URL(string: "https://example.com/v1")!,
                provider: "openai_compatible",
                requestedModel: "test-model",
                contextWindow: 32768,
                maxOutputTokens: 2048,
                usageMapping: "unsupported",
                streamUsageSupport: "unknown"
            )
        ).data
    )
    let intent = AINewSessionEvent(
        sessionID: session.id,
        type: .toolIntent,
        turnID: turnID,
        requestID: requestID,
        payload: try JSONEncoder().encode(AIToolIntentEventPayload(callID: intentID, commandDigest: "digest", target: session.target, permissionVersion: 1))
    )
    let laterIntent = AINewSessionEvent(
        sessionID: session.id,
        type: .toolIntent,
        turnID: turnID,
        requestID: laterRequestID,
        payload: try JSONEncoder().encode(AIToolIntentEventPayload(callID: intentID, commandDigest: "digest", target: session.target, permissionVersion: 1))
    )
    let result = AINewSessionEvent(
        sessionID: session.id,
        type: .toolResult,
        turnID: turnID,
        requestID: requestID,
        payload: try JSONEncoder().encode(AIToolResultEventPayload(callID: intentID, messageID: UUID(), name: "run_command", content: "done", completion: .completed, exitCode: 0, backend: .terminal))
    )
    _ = try await store.append([started, intent, laterIntent, result], expectedRevision: session.revision)

    let report = try await store.recoverInterruptedSessions()
    #expect(report.interruptedTurnIDs == [turnID])
    #expect(report.unknownCallKeys.count == 1)
    #expect(report.unknownCallKeys[0].contains(laterRequestID.uuidString))
    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.turnStates[turnID] == "interrupted")
    let again = try await store.recoverInterruptedSessions()
    #expect(again.interruptedTurnIDs.isEmpty)
}

@Test("Fork copies a closed prefix without inheriting live state")
func forkCopiesClosedPrefix() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIForkTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let turnID = UUID()
    let started = AINewSessionEvent(
        sessionID: session.id,
        type: .turnStarted,
        turnID: turnID,
        payload: AISessionEventPayload.turnStarted(
            turnID: turnID,
            target: session.target,
            model: AIModelSnapshot(
                profileID: UUID(),
                configurationRevision: 1,
                endpoint: URL(string: "https://example.com/v1")!,
                provider: "openai_compatible",
                requestedModel: "test-model",
                contextWindow: nil,
                maxOutputTokens: nil,
                usageMapping: "unsupported",
                streamUsageSupport: "unknown"
            )
        ).data
    )
    let ended = AINewSessionEvent(
        sessionID: session.id,
        type: .turnEnded,
        turnID: turnID,
        payload: AISessionEventPayload.turnEnded(turnID: turnID, status: "completed", errorCode: nil).data
    )
    let receipt = try await store.append([started, ended], expectedRevision: session.revision)
    let fork = try await store.fork(sessionID: session.id, throughSequence: receipt.lastSequence)
    #expect(fork.parentSessionID == session.id)
    #expect(fork.permission == AIPermissionMode.readOnly)
    #expect(fork.turnStates[turnID] == "completed")
    let source = try await store.load(sessionID: session.id)
    #expect(source.revision == receipt.revision)
}

@Test("Deleting a terminal physically removes its sessions, requests, and stale write targets")
func terminalDeletionRemovesOwnedSessionDataAndBlocksStaleWriters() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AITerminalDeletionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(
        directory: directory,
        executionHistoryTombstonesURL: directory.appendingPathComponent("execution-history-deleted-terminals.json")
    )
    let terminalID = UUID()
    let otherTerminalID = UUID()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ownedTarget = AITargetSnapshot(hostID: nil, terminalSessionID: terminalID, workingDirectory: "/tmp/owned", displayName: "owned")
    let otherTarget = AITargetSnapshot(hostID: nil, terminalSessionID: otherTerminalID, workingDirectory: "/tmp/other", displayName: "other")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let source = directory.appendingPathComponent("conversations.json")
    let legacyOwned = ConversationRecord(
        id: UUID(), targetHostID: nil, targetName: "owned", title: "owned legacy",
        messages: [ChatMessage(role: "user", content: "owned legacy content")], updatedAt: Date(),
        terminalSessionID: terminalID
    )
    let legacyOther = ConversationRecord(
        id: UUID(), targetHostID: nil, targetName: "other", title: "other legacy",
        messages: [ChatMessage(role: "user", content: "other legacy content")], updatedAt: Date(),
        terminalSessionID: otherTerminalID
    )
    try encoder.encode([legacyOwned, legacyOther]).write(to: source, options: .atomic)
    let migration = try await store.migrateLegacyArchive(sourceURL: source)
    let owned = try await store.create(target: ownedTarget, modelProfileID: nil)
    let other = try await store.create(target: otherTarget, modelProfileID: nil)

    let turnID = UUID()
    let requestID = UUID()
    let owner = AIRequestOwner(sessionID: owned.id, turnID: turnID, maintenanceID: nil, stepIndex: 0, purpose: "chat", attemptIndex: 0)
    let model = AIModelSnapshot(
        profileID: UUID(), configurationRevision: 1,
        endpoint: URL(string: "https://example.com/v1")!, provider: "openai_compatible",
        requestedModel: "test-model", contextWindow: nil, maxOutputTokens: nil,
        usageMapping: "unsupported", streamUsageSupport: "unknown"
    )
    try await store.startRequest(owner: owner, requestID: requestID, model: model, requestBody: Data("private request".utf8))
    _ = try await store.append([
        AINewSessionEvent(sessionID: owned.id, type: .userMessage, turnID: turnID,
                          payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "private transcript").data)
    ], expectedRevision: owned.revision + 1)

    try await store.deleteTerminalHistory(terminalID: terminalID)

    let deletionTombstones = directory.appendingPathComponent("execution-history-deleted-terminals.json")
    #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: deletionTombstones)) == [terminalID.uuidString])

    #expect(Set(try await store.list().map(\.id)) == Set([other.id, legacyOther.id]))
    #expect(try await store.usageForSession(sessionID: owned.id).requestCount == 0)
    await #expect(throws: AISessionStoreError.sessionMissing) {
        _ = try await store.load(sessionID: owned.id)
    }
    await #expect(throws: AISessionStoreError.sessionMissing) {
        _ = try await store.create(sessionID: owned.id, target: ownedTarget, modelProfileID: nil)
    }
    await #expect(throws: AISessionStoreError.sessionMissing) {
        _ = try await store.load(sessionID: legacyOwned.id)
    }
    await #expect(throws: AISessionStoreError.sessionMissing) {
        _ = try await store.append([
            AINewSessionEvent(sessionID: owned.id, type: .userMessage,
                              payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "stale write").data)
        ], expectedRevision: 0)
    }
    #expect(try await store.load(sessionID: other.id).target.terminalSessionID == otherTerminalID)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let sourceRecords = try decoder.decode([ConversationRecord].self, from: Data(contentsOf: source))
    let backupRecords = try decoder.decode([ConversationRecord].self, from: Data(contentsOf: URL(fileURLWithPath: migration.backupPath)))
    #expect(sourceRecords.map(\.id) == [legacyOther.id])
    #expect(backupRecords.map(\.id) == [legacyOther.id])
}

@Test("Failed terminal cleanup stays visible and resumes after the archive is repaired")
func terminalCleanupFailureResumesFromDurableBarrier() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AITerminalCleanupRetry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let terminalID = UUID()
    let otherTerminalID = UUID()
    let owned = ConversationRecord(
        id: UUID(), targetHostID: nil, targetName: "owned", title: "owned history",
        messages: [ChatMessage(role: "user", content: "must be removed")], updatedAt: Date(),
        terminalSessionID: terminalID
    )
    let other = ConversationRecord(
        id: UUID(), targetHostID: nil, targetName: "other", title: "other history",
        messages: [ChatMessage(role: "user", content: "must remain")], updatedAt: Date(),
        terminalSessionID: otherTerminalID
    )
    let source = directory.appendingPathComponent("conversations.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let originalArchive = try encoder.encode([owned, other])
    try originalArchive.write(to: source, options: .atomic)

    func deleteWithBrokenArchive() async throws -> AIMigrationReport {
        let store = AISessionStore(
            directory: directory,
            executionHistoryTombstonesURL: directory.appendingPathComponent("execution-history-deleted-terminals.json")
        )
        let migration = try await store.migrateLegacyArchive(sourceURL: source)
        #expect(Set(try await store.list().map(\.id)) == Set([owned.id, other.id]))

        // Simulate an unreadable archive after the transactional DB deletion has committed.
        try Data("not-json".utf8).write(to: source, options: .atomic)
        await #expect(throws: AISessionStoreError.self) {
            try await store.deleteTerminalHistory(terminalID: terminalID)
        }
        await #expect(throws: AISessionStoreError.sessionMissing) {
            _ = try await store.load(sessionID: owned.id)
        }
        #expect(try await store.load(sessionID: other.id).target.terminalSessionID == otherTerminalID)
        return migration
    }
    let migration = try await deleteWithBrokenArchive()

    // A fresh store instance models application restart and must finish both copies.
    try originalArchive.write(to: source, options: .atomic)
    let restartedStore = AISessionStore(
        directory: directory,
        executionHistoryTombstonesURL: directory.appendingPathComponent("execution-history-deleted-terminals.json")
    )
    try await restartedStore.resumeTerminalCleanup()

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let sourceRecords = try decoder.decode([ConversationRecord].self, from: Data(contentsOf: source))
    let backupRecords = try decoder.decode([ConversationRecord].self, from: Data(contentsOf: URL(fileURLWithPath: migration.backupPath)))
    #expect(sourceRecords.map(\.id) == [other.id])
    #expect(backupRecords.map(\.id) == [other.id])
    #expect(try await restartedStore.list().map(\.id) == [other.id])
}

@Test("Every model attempt has a durable start and terminal status even without usage data")
func requestLedgerStoresFailedAttemptWithoutUsage() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIRequestLedgerTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let turnID = UUID()
    let requestID = UUID()
    let owner = AIRequestOwner(sessionID: session.id, turnID: turnID, maintenanceID: nil, stepIndex: 1, purpose: "conversation", attemptIndex: 0)
    let model = AIModelSnapshot(
        profileID: UUID(), configurationRevision: 1,
        endpoint: URL(string: "https://example.com/v1")!, provider: "openai_compatible",
        requestedModel: "test-model", contextWindow: 32768, maxOutputTokens: nil,
        usageMapping: "unsupported", streamUsageSupport: "unknown"
    )
    try await store.startRequest(owner: owner, requestID: requestID, model: model, requestBody: Data("{\"model\":\"test-model\"}".utf8))
    try await store.startRequest(owner: owner, requestID: requestID, model: model, requestBody: Data("{\"model\":\"test-model\"}".utf8))
    try await store.finishRequest(owner: owner, requestID: requestID, status: "failed")

    let events = try await store.readEvents(sessionID: session.id)
    #expect(events.filter { $0.type == .requestStarted }.count == 1)
    #expect(events.filter { $0.type == .requestSettled }.count == 1)
    #expect(events.last?.requestID == requestID)
    let usage = try await store.usageForTurn(sessionID: session.id, turnID: turnID)
    #expect(usage.requestCount == 1)
    #expect(usage.modelRequestCounts["test-model"] == 1)
    #expect(usage.usage.totalInput.state == .unknown)
}

@Test("Legacy histories with unknown terminal ownership are deleted without affecting owned histories", arguments: [true, false])
func unassignedLegacyHistoryIsDeletedDirectly(_ isoDates: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIUnassignedDeletionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeLegacyFile(in: directory, isoDates: isoDates)
    let store = AISessionStore(directory: directory)
    let migration = try await store.migrateLegacyArchive(sourceURL: source)
    let legacyID = try #require(try await store.list().first?.id)
    let owned = try await store.create(
        target: AITargetSnapshot(hostID: nil, terminalSessionID: UUID(), workingDirectory: nil, displayName: "kept"),
        modelProfileID: nil
    )

    try await store.deleteUnassignedHistory()

    #expect(try await store.list().map(\.id) == [owned.id])
    await #expect(throws: AISessionStoreError.sessionMissing) {
        _ = try await store.load(sessionID: legacyID)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode([ConversationRecord].self, from: Data(contentsOf: source)).isEmpty)
    #expect(try decoder.decode([ConversationRecord].self, from: Data(contentsOf: URL(fileURLWithPath: migration.backupPath))).isEmpty)
}

@Test("Context projection commits atomically and rejects stale revisions")
func contextProjectionCommitIsAtomic() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIProjectionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let messageID = UUID()
    let messageEvent = AINewSessionEvent(
        sessionID: session.id,
        type: .userMessage,
        payload: AISessionEventPayload.userMessage(messageID: messageID, content: "old task").data
    )
    _ = try await store.append([messageEvent], expectedRevision: session.revision)
    let sourceContextRevision: Int64 = 1
    let compactionID = UUID()
    let events = [
        AINewSessionEvent(
            sessionID: session.id,
            type: .compactionStarted,
            payload: try JSONEncoder().encode(StartedPayload(compactionID: compactionID, sourceContextRevision: sourceContextRevision))
        ),
        AINewSessionEvent(
            sessionID: session.id,
            type: .compactionCommitted,
            payload: try JSONEncoder().encode(CommittedPayload(compactionID: compactionID, summary: "old summary", sourceMessageIDs: [messageID.uuidString]))
        ),
        AINewSessionEvent(
            sessionID: session.id,
            type: .contextProjected,
            payload: try JSONEncoder().encode(AIContextProjectionPayload(
                compactionID: compactionID,
                summary: "old summary",
                sourceMessageIDs: [messageID.uuidString]
            ))
        )
    ]

    let committed = try await store.commitContextProjection(
        sessionID: session.id,
        events: events,
        expectedContextRevision: sourceContextRevision
    )
    #expect(committed.revision == 5)
    #expect(committed.contextRevision == 2)

    await #expect(throws: AISessionStoreError.staleRevision) {
        try await store.commitContextProjection(
            sessionID: session.id,
            events: events.map { event in
                var duplicate = event
                duplicate.eventID = UUID()
                return duplicate
            },
            expectedContextRevision: sourceContextRevision
        )
    }
    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.revision == 5)
    #expect(loaded.contextRevision == 2)
    #expect(loaded.summaryIDs == [compactionID])
    #expect(loaded.contextSummary == "old summary")
    #expect(loaded.summarizedMessageIDs == Set([messageID]))
    #expect(loaded.messages.count == 1)
}

@Test("Permission, model and context events restore projected session state")
func sessionStateEventsRestoreSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIStateEventsTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let profileID = UUID()
    var configuration = AIContextConfiguration.standard
    configuration.contextWindowOverride = 32768
    let events = [
        AINewSessionEvent(
            sessionID: session.id,
            type: .permissionChanged,
            payload: AISessionEventPayload.permissionChanged(old: .readOnly, new: .fullAccess).data
        ),
        AINewSessionEvent(
            sessionID: session.id,
            type: .modelSelected,
            payload: AISessionEventPayload.modelSelected(profileID: profileID, contextWindow: 32768).data
        ),
        AINewSessionEvent(
            sessionID: session.id,
            type: .contextConfigured,
            payload: AISessionEventPayload.contextConfigured(configuration: configuration).data
        )
    ]
    _ = try await store.append(events, expectedRevision: session.revision)
    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.permission == .fullAccess)
    #expect(loaded.permissionVersion == 2)
    #expect(loaded.modelProfileID == profileID)
    #expect(loaded.configuration == configuration)
}

@Test("A second session store cannot acquire the database while another store owns its lock")
func sessionStoreRejectsCompetingProcessLock() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AISessionProcessLock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func createWhileHoldingLock() async throws -> UUID {
        let firstStore = AISessionStore(directory: directory)
        let created = try await firstStore.create(target: .local(workingDirectory: nil), modelProfileID: nil)
        let competingStore = AISessionStore(directory: directory)
        await #expect(throws: AISessionStoreError.self) {
            _ = try await competingStore.list()
        }
        #expect(try await firstStore.load(sessionID: created.id).id == created.id)
        return created.id
    }

    let sessionID = try await createWhileHoldingLock()
    let reopenedStore = AISessionStore(directory: directory)
    #expect(try await reopenedStore.list().map(\.id) == [sessionID])
}

@Test("A newly created session retains its selected profile and profile-scoped context configuration")
func createdSessionRetainsProfileAndContextConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AICreatedProfileContext-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let profileID = UUID()
    var configuration = AIContextConfiguration.standard
    configuration.contextWindowOverride = 100_000
    configuration.outputReserve = 10_000
    let created = try await store.create(
        target: .local(workingDirectory: nil),
        modelProfileID: profileID,
        configuration: configuration
    )

    let loaded = try await store.load(sessionID: created.id)

    #expect(loaded.modelProfileID == profileID)
    #expect(loaded.configuration == configuration)
}

@Test("Profile-scoped context configurations remain isolated when switching models")
func profileContextConfigurationsRemainIsolatedAcrossModelSwitches() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIProfileContextIsolation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let profileA = UUID()
    let profileB = UUID()
    var configurationA = AIContextConfiguration.standard
    configurationA.contextWindowOverride = 96_000
    configurationA.outputReserve = 8_000
    var configurationB = AIContextConfiguration.standard
    configurationB.contextWindowOverride = 32_000
    configurationB.outputReserve = 4_000
    let session = try await store.create(
        target: .local(workingDirectory: nil), modelProfileID: profileA,
        configuration: configurationA
    )

    var revision = session.revision
    for profileID in [profileB, profileA, profileB] {
        let selected = AINewSessionEvent(
            sessionID: session.id, type: .modelSelected,
            payload: AISessionEventPayload.modelSelected(profileID: profileID, contextWindow: nil).data
        )
        let selectedReceipt = try await store.append([selected], expectedRevision: revision)
        revision = selectedReceipt.revision
        if profileID == profileB, try await store.load(sessionID: session.id).configuration == .standard {
            let configured = AINewSessionEvent(
                sessionID: session.id, type: .profileContextConfigured,
                payload: AISessionEventPayload.profileContextConfigured(profileID: profileB, configuration: configurationB).data
            )
            revision = try await store.append([configured], expectedRevision: revision).revision
        }
        let loaded = try await store.load(sessionID: session.id)
        #expect(loaded.modelProfileID == profileID)
        #expect(loaded.configuration == (profileID == profileA ? configurationA : configurationB))
    }
}
