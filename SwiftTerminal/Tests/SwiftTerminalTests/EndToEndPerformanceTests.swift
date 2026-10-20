import AppKit
import Darwin
import Foundation
import Testing
@testable import SwiftTerminal

private func currentFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

@Test("End-to-end PTY input echo latency and memory peak stay bounded", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_PERF_TESTS"] == "1"))
@MainActor
func endToEndPTYInputLatencyAndMemoryPeak() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TerminalPerfE2E-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    pane.installProcessDelegate(onExit: nil)
    pane.startProcess(executable: "/bin/zsh", args: ["-i"],
        environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin", "HISTFILE="],
        execName: nil, currentDirectory: root.path)
    try await Task.sleep(for: .milliseconds(800))
    let terminal = try #require(pane.terminal)

    // Real PTY round trip: one keystroke in, echo visible in the rendered buffer.
    var samples: [Double] = []
    for round in 0..<50 {
        let marker = "E\(round)"
        let sentAt = Date()
        pane.send(data: Array("printf \(marker)\r".utf8)[...])
        var observed = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && !observed {
            try await Task.sleep(for: .milliseconds(10))
            let count = TerminalRunReading.lineCount(terminal)
            for row in max(0, count - 400)..<count {
                if TerminalRunReading.lineText(terminal, row: row)?.contains(marker) == true { observed = true }
            }
        }
        #expect(observed)
        guard observed else { continue }
        samples.append(Date().timeIntervalSince(sentAt) * 1000)
        pane.send(data: Array("\u{15}".utf8)[...])
        try await Task.sleep(for: .milliseconds(40))
    }
    let sorted = samples.sorted()
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    print("PERF_E2E p95_ms=\(String(format: "%.2f", p95)) samples=\(samples.count)")
    #expect(p95 < 300)

    pane.send(data: Array("exit\r".utf8)[...])
    try await Task.sleep(for: .milliseconds(300))
    if pane.process?.running == true { pane.terminate() }

    // Memory peak while refreshing 300 sessions with 100 events each.
    let before = currentFootprintBytes()
    let store = AISessionStore(directory: root.appendingPathComponent("sessions"))
    var sessions: [AISessionSnapshot] = []
    for index in 0..<300 {
        let session = try await store.create(
            target: .local(workingDirectory: "/perf/\(index)"), modelProfileID: nil)
        var events: [AINewSessionEvent] = []
        for step in 0..<100 {
            events.append(AINewSessionEvent(sessionID: session.id, type: .userMessage,
                payload: AISessionEventPayload.userMessage(messageID: UUID(), content: "事件 \(step)").data))
        }
        _ = try await store.append(events, expectedRevision: session.revision)
        sessions.append(session)
    }
    var peakDuringRefresh = currentFootprintBytes()
    for session in sessions {
        _ = try? await store.load(sessionID: session.id)
        peakDuringRefresh = max(peakDuringRefresh, currentFootprintBytes())
    }
    let growthMB = Double(peakDuringRefresh - before) / 1_048_576
    print("PERF_E2E memory_growth_mb=\(String(format: "%.1f", growthMB))")
    #expect(growthMB < 800)
    try FileManager.default.removeItem(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}
