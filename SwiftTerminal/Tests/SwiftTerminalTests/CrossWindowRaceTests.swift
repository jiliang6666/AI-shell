import Foundation
import CSQLite
import Testing
@testable import SwiftTerminal

@Test("Deleting a terminal while writes are in flight keeps the outcome consistent and rejects late writes")
func terminalDeletionRacingInflightWriteStaysConsistent() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIDeleteRace-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory, executionHistoryTombstonesURL: directory.appendingPathComponent("deleted-terminals.json"))
    let terminalID = UUID()
    var target = AITargetSnapshot.local(workingDirectory: "/tmp")
    target = AITargetSnapshot(
        hostID: nil, terminalSessionID: terminalID, workingDirectory: "/tmp", displayName: "本机")
    let session = try await store.create(target: target, modelProfileID: nil)

    var blocker: OpaquePointer?
    let databaseFile = directory.appendingPathComponent("ai-sessions.sqlite3").path
    #expect(sqlite3_open(databaseFile, &blocker) == SQLITE_OK)
    defer { sqlite3_close(blocker) }
    #expect(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)

    // The in-flight write (an SMB/native tool result settling after a stop, or a
    // streaming archive) blocks on the same database while the deletion starts.
    let lateEvent = AINewSessionEvent(sessionID: session.id, type: .userMessage,
        payload: AISessionEventPayload.userMessage(
            messageID: UUID(), content: "SMB 挂载结果（在途晚到写入）"
        ).data)
    let lateWrite = Task { try await store.append([lateEvent], expectedRevision: session.revision) }
    let deletion = Task { try await store.deleteTerminalHistory(terminalID: terminalID) }
    try await Task.sleep(for: .milliseconds(200))

    #expect(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
    let writeOutcome = await lateWrite.result
    let deleteOutcome = await deletion.result

    // Exactly one side may fail visibly; the other side must have committed.
    let writeFailed = (try? writeOutcome.get()) == nil
    let deleteFailed = (try? deleteOutcome.get()) == nil
    #expect(writeFailed != deleteFailed || (!writeFailed && !deleteFailed))

    if deleteFailed {
        // The deletion hit the in-flight write and failed visibly; a retry must succeed.
        try await store.deleteTerminalHistory(terminalID: terminalID)
    }
    let remaining = try await store.list(limit: 10)
    #expect(remaining.isEmpty)
    await #expect(throws: AISessionStoreError.self) {
        try await store.load(sessionID: session.id)
    }

    // A late writer racing after the committed deletion is rejected and cannot
    // resurrect history for the deleted terminal.
    await #expect(throws: AISessionStoreError.self) {
        try await store.append([lateEvent], expectedRevision: session.revision)
    }
    #expect(try await store.list(limit: 10).isEmpty)
}

@Test("The deletion barrier rejects creating a new session for a deleted terminal")
func deletionBarrierRejectsNewSessions() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIDeleteBarrier-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory, executionHistoryTombstonesURL: directory.appendingPathComponent("deleted-terminals.json"))
    let terminalID = UUID()
    let target = AITargetSnapshot(
        hostID: nil, terminalSessionID: terminalID, workingDirectory: nil, displayName: "SSH")
    let session = try await store.create(target: target, modelProfileID: nil)
    try await store.deleteTerminalHistory(terminalID: terminalID)
    await #expect(throws: AISessionStoreError.self) {
        try await store.create(target: target, modelProfileID: nil)
    }
    await #expect(throws: AISessionStoreError.self) {
        try await store.load(sessionID: session.id)
    }
}
