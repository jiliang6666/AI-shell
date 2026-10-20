import Foundation
import XCTest
@testable import SwiftTerminal

/// Opt-in Release benchmark. Never reads the user's database or calls a provider.
final class AIPerformanceAuditTests: XCTestCase, @unchecked Sendable {
    func testReleaseStoreAndContextDataPaths() async throws {
        #if DEBUG
        throw XCTSkip("Performance evidence requires a Release build")
        #else
        guard let evidencePath = ProcessInfo.processInfo.environment["AI_PERFORMANCE_EVIDENCE"] else {
            throw XCTSkip("Set AI_PERFORMANCE_EVIDENCE and run swift test -c release --filter AIPerformanceAuditTests")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIPerformance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let currentID = try await makeFixture(directory: directory)
        let fixtureDatabase = directory.appendingPathComponent("ai-sessions.sqlite3")
        var listSamples: [Double] = []
        var contextSamples: [Double] = []
        var refreshSamples: [Double] = []
        let clock = ContinuousClock()
        for sample in 0..<5 {
            let listDirectory = try copiedFixture(fixtureDatabase, into: directory, name: "list-\(sample)")
            let listStore = AISessionStore(directory: listDirectory)
            let listStart = clock.now
            let page = try await listStore.list(limit: 50)
            listSamples.append(milliseconds(listStart.duration(to: clock.now)))
            XCTAssertEqual(page.count, 50)

            let contextDirectory = try copiedFixture(fixtureDatabase, into: directory, name: "context-\(sample)")
            let contextStore = AISessionStore(directory: contextDirectory)
            let contextStart = clock.now
            let snapshot = try await contextStore.load(sessionID: currentID)
            let estimate = AIContextEstimator.messages(snapshot.messages.map { message in
                var value = message
                if value.role == "tool", let content = value.content { value.content = AIToolOutputLimiter.modelProjection(content) }
                return value
            })
            let budget = AIContextBudgetCalculator.budget(configuration: snapshot.configuration, knownCapacity: nil)
            contextSamples.append(milliseconds(contextStart.duration(to: clock.now)))
            XCTAssertEqual(snapshot.messages.count, 99)
            XCTAssertGreaterThan(estimate, 0)
            XCTAssertNil(budget.capacity)

            let refreshDirectory = try copiedFixture(fixtureDatabase, into: directory, name: "refresh-\(sample)")
            let refreshStore = AISessionStore(directory: refreshDirectory)
            let coordinator = await AISessionCoordinator(store: refreshStore)
            let refreshStart = clock.now
            await coordinator.refresh()
            refreshSamples.append(milliseconds(refreshStart.duration(to: clock.now)))
            let count = await coordinator.records.count
            XCTAssertEqual(count, 300)
        }
        let evidence: [String: Any] = [
            "executed_at": ISO8601DateFormatter().string(from: Date()),
            "build": "Release arm64, SwiftPM, no network/provider, temporary SQLite database",
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "logical_processors": ProcessInfo.processInfo.processorCount,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "fixture": ["sessions": 300, "events_per_session": 100, "message_triplets_per_session": 33, "tool_result_utf8_bytes": 8192, "first_page_size": 50],
            "repetitions": 5,
            "p95_method": "nearest_rank; for n=5 the maximum sample",
            "cold_definition": "new store and connection per sample; OS cache not flushed",
            "operations": [
                "cold_session_first_page": result(listSamples),
                "context_load_projection_estimator_only": result(contextSamples),
                "history_coordinator_refresh_all_300": result(refreshSamples)
            ],
            "limitations": ["Context measurement excludes TerminalAIModel, tool schema and system prompt estimation, SwiftUI layout and repeated body evaluation.", "Coordinator refresh is the real data path but excludes UI rendering.", "No terminal input responsiveness, network latency, CPU or memory peak acceptance measurement.", "T51 is not fully verified by these measurements."]
        ]
        let output = URL(fileURLWithPath: evidencePath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("AI performance evidence written to \(output.path)")
        #endif
    }

    private func copiedFixture(_ databaseFile: URL, into parent: URL, name: String) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: databaseFile, to: directory.appendingPathComponent("ai-sessions.sqlite3"))
        return directory
    }

    private func makeFixture(directory: URL) async throws -> UUID {
        let store = AISessionStore(directory: directory)
        let toolText = String(repeating: "fixture output. ", count: 512) // exactly 8 KiB
        var latest = UUID()
        for index in 0..<300 {
            let session = try await store.create(target: .local(workingDirectory: "/tmp"), modelProfileID: nil)
            latest = session.id
            var events: [AINewSessionEvent] = []
            for step in 0..<33 {
                let callID = "fixture-\(index)-\(step)"
                let user = AISessionEventPayload.userMessage(messageID: UUID(), content: "检查磁盘 status \(step)")
                let assistant = ChatMessage(role: "assistant", content: "检查结果", toolCalls: [ChatToolCall(id: callID, function: ChatFunctionCall(name: "run_inspection", arguments: "{\"kind\":\"disk\"}"))])
                let result = AIToolResultEventPayload(callID: callID, messageID: UUID(), name: "run_inspection", content: toolText, completion: .completed, exitCode: 0, backend: .restrictedInspection)
                events.append(AINewSessionEvent(sessionID: session.id, type: .userMessage, payload: user.data))
                events.append(AINewSessionEvent(sessionID: session.id, type: .assistantMessage, payload: AISessionEventPayload.assistantMessage(messageID: assistant.id, stored: AIStoredMessage(message: assistant)).data))
                events.append(AINewSessionEvent(sessionID: session.id, type: .toolResult, payload: try JSONEncoder().encode(result)))
            }
            _ = try await store.append(events, expectedRevision: session.revision)
            let count = try await store.readEvents(sessionID: session.id, limit: 200).count
            XCTAssertEqual(count, 100)
        }
        return latest
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    private func result(_ samples: [Double]) -> [String: Any] {
        ["samples_ms": samples, "p95_ms": samples.sorted()[4], "under_300_ms": samples.max()! <= 300]
    }
}
