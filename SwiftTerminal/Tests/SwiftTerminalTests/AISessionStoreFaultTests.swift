import CSQLite
import Darwin
import Foundation
import Testing
@testable import SwiftTerminal

private func editSessionDatabase(_ file: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(file.path, &database) == SQLITE_OK else {
        throw NSError(domain: "SessionFaultFixture", code: 1)
    }
    defer { sqlite3_close(database) }
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
        throw NSError(domain: "SessionFaultFixture", code: Int(result))
    }
}

@Test("Invalid event payloads are rejected before a batch can change history", arguments: ["future", "empty", "mismatch", "turn", "tool", "projection", "assistant", "compaction"])
func sessionStoreRejectsInvalidEventBatch(_ fault: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIInvalidBatch-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let valid = AINewSessionEvent(sessionID: session.id, type: .userMessage,
        payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "preserved").data)
    var invalid = valid
    invalid.eventID = UUID()
    switch fault {
    case "future": invalid.payloadVersion = 2
    case "empty": invalid.payload = Data("{}".utf8)
    case "mismatch": invalid.payload = AISessionEventPayload.permissionChanged(old: .readOnly, new: .fullAccess).data
    case "turn":
        invalid.type = .turnEnded
        invalid.turnID = UUID()
        invalid.payload = AISessionEventPayload.turnEnded(turnID: UUID(), status: "completed", errorCode: nil).data
    case "tool":
        invalid.type = .toolResult
        invalid.payload = Data(#"{"callID":"only-an-id"}"#.utf8)
    case "assistant":
        invalid.type = .assistantMessage
        var stored = AIStoredMessage(message: ChatMessage(role: "assistant", content: "reply"))
        stored.toolCallsJSON = Data("broken tool calls".utf8)
        invalid.payload = AISessionEventPayload.assistantMessage(messageID: stored.id, stored: stored).data
    case "compaction":
        invalid.type = .compactionEnded
        invalid.payload = try JSONEncoder().encode(["compactionID": UUID()])
    default:
        invalid.type = .contextProjected
        invalid.payload = try JSONEncoder().encode(AIContextProjectionPayload(compactionID: UUID(), summary: "summary", sourceMessageIDs: ["not-a-uuid"]))
    }
    await #expect(throws: AISessionStoreError.self) {
        try await store.append([valid, invalid], expectedRevision: session.revision)
    }
    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.revision == session.revision)
    #expect(loaded.messages.isEmpty)
    #expect(try await store.readEvents(sessionID: session.id).count == 1)
}

@Test("Corrupt events cannot be silently omitted by load or crash recovery", arguments: ["future", "unknown", "empty", "mismatch", "identifier"])
func sessionStoreFailsClosedOnCorruptEvent(_ fault: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AICorruptEvent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let event = AINewSessionEvent(sessionID: session.id, type: .userMessage,
        payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "original").data)
    _ = try await store.append([event], expectedRevision: session.revision)
    let assignment: String
    switch fault {
    case "future": assignment = "payload_version=2"
    case "unknown": assignment = "event_type='future_event'"
    case "empty": assignment = "payload_json='{}'"
    case "mismatch": assignment = "event_type='permission_changed'"
    default: assignment = "turn_id='not-a-uuid'"
    }
    let file = directory.appendingPathComponent("ai-sessions.sqlite3")
    try editSessionDatabase(file, sql: "UPDATE events SET \(assignment) WHERE event_id='\(event.eventID.uuidString)';")
    let bytes = try Data(contentsOf: file)
    await #expect(throws: AISessionStoreError.self) { try await store.load(sessionID: session.id) }
    await #expect(throws: AISessionStoreError.self) { try await store.readEvents(sessionID: session.id) }
    await #expect(throws: AISessionStoreError.self) { try await store.recoverInterruptedSessions() }
    if fault == "future" || fault == "unknown" {
        await #expect(throws: AISessionStoreError.unsupportedSchema) { try await store.load(sessionID: session.id) }
    }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test("A future schema is left untouched and a failed open releases its ownership lock")
func futureSessionSchemaPreservesDatabaseAndReleasesLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIFutureSchema-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("ai-sessions.sqlite3")
    try editSessionDatabase(file, sql: "PRAGMA journal_mode=WAL; PRAGMA user_version=\(AISessionStore.schemaVersion + 1); CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('preserved');")
    let bytes = try Data(contentsOf: file)
    let first = AISessionStore(directory: directory)
    await #expect(throws: AISessionStoreError.unsupportedSchema) { try await first.list() }
    #expect(try Data(contentsOf: file) == bytes)
    let second = AISessionStore(directory: directory)
    await #expect(throws: AISessionStoreError.unsupportedSchema) { try await second.list() }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test("Opening a corrupt database preserves the original file")
func corruptSessionDatabaseIsNotReplaced() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AICorruptDatabase-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("ai-sessions.sqlite3")
    let bytes = Data("damaged database fixture".utf8)
    try bytes.write(to: file)
    let store = AISessionStore(directory: directory)
    await #expect(throws: AISessionStoreError.self) { try await store.list() }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test("Symlinked database and lock paths are rejected without modifying the target", arguments: ["ai-sessions.sqlite3", "ai-sessions.lock"])
func sessionStoreRejectsSymlinkFiles(_ name: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISymlink-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    let bytes = Data("untouched target".utf8)
    try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: target)
    let store = AISessionStore(directory: directory)
    await #expect(throws: AISessionStoreError.self) { try await store.list() }
    #expect(try Data(contentsOf: target) == bytes)
}

private func probeSessionLock(_ file: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", "open(my $lock, '+<', $ARGV[0]) or exit 24; flock($lock, 6) or exit 23; exit 0;", file.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Test("A second OS process cannot acquire the session lock until the store is released")
func sessionOwnershipLockRejectsSecondProcess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIProcessLock-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = directory.appendingPathComponent("ai-sessions.lock")
    func holdStore() async throws {
        let store = AISessionStore(directory: directory)
        let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
        #expect(try probeSessionLock(lock) == 23)
        #expect(try await store.load(sessionID: session.id).id == session.id)
    }
    try await holdStore()
    #expect(try probeSessionLock(lock) == 0)
}

@Test("SQLite write contention times out visibly and leaves the transaction retryable")
func sessionStoreWriteContentionCanRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIBusyDatabase-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    var writer: OpaquePointer?
    #expect(sqlite3_open(directory.appendingPathComponent("ai-sessions.sqlite3").path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
    let event = AINewSessionEvent(sessionID: session.id, type: .userMessage,
        payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "retryable").data)
    await #expect(throws: AISessionStoreError.self) { try await store.append([event], expectedRevision: session.revision) }
    #expect(sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
    #expect(try await store.load(sessionID: session.id).messages.isEmpty)
    let receipt = try await store.append([event], expectedRevision: session.revision)
    #expect(receipt.revision == session.revision + 1)
    #expect(try await store.load(sessionID: session.id).messages.first?.content == "retryable")
}

@Test("A read-only database file fails visibly, preserves the original file and recovers after permissions are restored")
func readOnlySessionDatabaseFailsVisiblyAndRecovers() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIReadOnlyDatabase-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseFile = directory.appendingPathComponent("ai-sessions.sqlite3")
    var seed: OpaquePointer?
    #expect(sqlite3_open(databaseFile.path, &seed) == SQLITE_OK)
    #expect(sqlite3_close(seed) == SQLITE_OK)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: databaseFile.path)

    let blocked = AISessionStore(directory: directory)
    await #expect(throws: AISessionStoreError.self) {
        try await blocked.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: databaseFile.path)
    #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o444))

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseFile.path)
    let recovered = AISessionStore(directory: directory)
    let session = try await recovered.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let event = AINewSessionEvent(sessionID: session.id, type: .userMessage,
        payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "恢复后可写").data)
    let receipt = try await recovered.append([event], expectedRevision: session.revision)
    #expect(receipt.revision == session.revision + 1)
    #expect(try await recovered.load(sessionID: session.id).messages.count == 1)
}

@Test("A full database fails visibly on the live store and the same batch retries after space is restored", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_DISK_FULL_TESTS"] == "1"))
func databaseFullFaultFailsVisiblyAndRetries() async throws {
    signal(SIGXFSZ, SIG_IGN)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIDatabaseFull-\(UUID().uuidString)", isDirectory: true)
    defer {
        var unlimited = rlimit(rlim_cur: rlim_t(UInt64.max >> 1), rlim_max: rlim_t(UInt64.max >> 1))
        setrlimit(RLIMIT_FSIZE, &unlimited)
        try? FileManager.default.removeItem(at: directory)
    }
    var small = rlimit(rlim_cur: rlim_t(512 * 1024), rlim_max: rlim_t(UInt64.max >> 1))
    #expect(setrlimit(RLIMIT_FSIZE, &small) == 0)
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let smallEvent = AINewSessionEvent(sessionID: session.id, type: .userMessage,
        payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "限额内写入").data)
    let smallReceipt = try await store.append([smallEvent], expectedRevision: session.revision)

    let oversizedEvent = AINewSessionEvent(sessionID: session.id, type: .userMessage,
        payload: AISessionEventPayload.userMessage(messageID: UUID(), content: String(repeating: "满", count: 400_000)).data)
    await #expect(throws: AISessionStoreError.self) {
        try await store.append([oversizedEvent], expectedRevision: session.revision)
    }
    #expect(try await store.load(sessionID: session.id).messages.count == 1)

    var unlimited = rlimit(rlim_cur: rlim_t(UInt64.max >> 1), rlim_max: rlim_t(UInt64.max >> 1))
    #expect(setrlimit(RLIMIT_FSIZE, &unlimited) == 0)
    let receipt = try await store.append([oversizedEvent], expectedRevision: smallReceipt.revision)
    #expect(receipt.revision == smallReceipt.revision + 1)
    #expect(try await store.load(sessionID: session.id).messages.count == 2)
}

@Test("Older migration records use the event's stable message ID when restored")
func oldMigratedMessageUsesStableEventIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AILegacyIdentity-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let stableID = UUID()
    let original = AIStoredMessage(message: ChatMessage(role: "assistant", content: "preserved history"))
    #expect(original.id != stableID)
    let event = AINewSessionEvent(sessionID: session.id, type: .assistantMessage,
        payload: AISessionEventPayload.assistantMessage(messageID: stableID, stored: original).data)
    _ = try await store.append([event], expectedRevision: session.revision)
    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.messages.first?.id == stableID)
    #expect(loaded.messages.first?.content == "preserved history")
}

@Test("Legacy migration IDs stay deterministic across independent archive decodes")
func legacyMigrationMessageIDsAreDeterministic() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIDeterministicMigration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = ConversationRecord(id: UUID(), targetHostID: nil, targetName: "local", title: "legacy",
        messages: [ChatMessage(role: "user", content: "question"), ChatMessage(role: "assistant", content: "answer")],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode([record])
    func migrate(_ name: String) async throws -> [UUID] {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("conversations.json")
        try data.write(to: source)
        let store = AISessionStore(directory: directory)
        _ = try await store.migrateLegacyArchive(sourceURL: source)
        let loaded = try await store.load(sessionID: record.id)
        #expect(loaded.messages.map(\.content) == ["question", "answer"])
        return loaded.messages.map(\.id)
    }
    #expect(try await migrate("first") == migrate("second"))
}

@Test("Corrupt session metadata is reported as a storage failure instead of a missing session")
func corruptSessionMetadataFailsVisibly() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIMetadataFault-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    try editSessionDatabase(directory.appendingPathComponent("ai-sessions.sqlite3"),
        sql: "UPDATE sessions SET configuration_by_profile_json='{}bad' WHERE session_id='\(session.id.uuidString)';")
    await #expect {
        try await store.load(sessionID: session.id)
    } throws: { error in
        guard case .persistenceFailed = error as? AISessionStoreError else { return false }
        return true
    }
}

@Test("Crash recovery closes unfinished compactions without discarding committed projections", arguments: [true, false])
func interruptedCompactionRecoveryReleasesMaintenance(_ projectionCommitted: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AICompactionRecovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let compactionID = UUID()
    var events = [AINewSessionEvent(sessionID: session.id, type: .compactionStarted,
        payload: try JSONSerialization.data(withJSONObject: ["compactionID": compactionID.uuidString, "sourceContextRevision": 0]))]
    if projectionCommitted {
        events.append(AINewSessionEvent(sessionID: session.id, type: .contextProjected,
            payload: try JSONEncoder().encode(AIContextProjectionPayload(compactionID: compactionID, summary: "committed summary", sourceMessageIDs: []))))
    }
    _ = try await store.append(events, expectedRevision: session.revision)
    let report = try await store.recoverInterruptedSessions()
    #expect(report.sessionIDs == [session.id])
    #expect(report.discardedCompactionIDs == (projectionCommitted ? [] : [compactionID]))
    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.contextSummary == (projectionCommitted ? "committed summary" : nil))
    #expect(try await store.readEvents(sessionID: session.id).filter { $0.type == .compactionEnded }.count == 1)
    let again = try await store.recoverInterruptedSessions()
    #expect(again.sessionIDs.isEmpty)
    #expect(again.discardedCompactionIDs.isEmpty)
    try await store.delete(sessionID: session.id)
}
