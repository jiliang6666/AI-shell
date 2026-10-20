import Foundation
import Testing
@testable import SwiftTerminal

@Test("Terminal execution history deletion is durable, isolated, and blocks stale writes")
func terminalExecutionHistoryDeletionResumesAfterRestart() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExecutionHistoryDeletion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let history = directory.appendingPathComponent("execution-history.json")
    let tombstones = directory.appendingPathComponent("deleted-terminals.json")
    let terminalID = UUID()
    let otherTerminalID = UUID()
    let owned = ExecutionRecord(
        targetName: "owned", hostID: nil, command: "private command", output: "private output",
        exitCode: 0, startedAt: Date(), terminalSessionID: terminalID
    )
    let other = ExecutionRecord(
        targetName: "other", hostID: nil, command: "keep command", output: "keep output",
        exitCode: 0, startedAt: Date(), terminalSessionID: otherTerminalID
    )
    let encoder = JSONEncoder()
    let originalHistory = try encoder.encode([owned, other])
    try originalHistory.write(to: history, options: .atomic)

    try ExecutionHistoryStore.markTerminalDeleted(terminalID, tombstonesAt: tombstones)
    let corruptHistory = Data("not-json".utf8)
    try corruptHistory.write(to: history, options: .atomic)
    #expect(throws: AISessionStoreError.self) {
        try ExecutionHistoryStore.deleteHistory(terminalSessionID: terminalID, at: history, tombstonesAt: tombstones)
    }

    // The persisted barrier rejects command completions arriving after deletion began.
    ExecutionHistoryStore.append(
        ExecutionRecord(
            targetName: "owned", hostID: nil, command: "late command", output: "late output",
            exitCode: 0, startedAt: Date(), terminalSessionID: terminalID
        ),
        at: history,
        tombstonesAt: tombstones
    )
    #expect(try Data(contentsOf: history) == corruptHistory)

    // A fresh startup retry removes all stale copies and leaves other terminals intact.
    try originalHistory.write(to: history, options: .atomic)
    try ExecutionHistoryStore.resumeTerminalDeletions(at: history, tombstonesAt: tombstones)
    let remaining = try JSONDecoder().decode([ExecutionRecord].self, from: Data(contentsOf: history))
    #expect(remaining.map(\.id) == [other.id])
    #expect(try String(contentsOf: tombstones, encoding: .utf8).contains(terminalID.uuidString))
}
