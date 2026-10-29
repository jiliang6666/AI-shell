import AppKit
import Foundation
import Testing
@testable import SwiftTerminal

@Test("快捷执行保留当前目录、多行命令和交互输入", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func quickCommandPreservesShellAndInteractiveInput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickCommandPTY-\(UUID())")
    let startup = root.appendingPathComponent("startup")
    try FileManager.default.createDirectory(at: startup, withIntermediateDirectories: true)
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    defer {
        if pane.process?.running == true { pane.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    pane.installProcessDelegate()
    let integration = try #require(ZshShellIntegration.prepare(
        generation: pane.connectionGeneration,
        directory: root.appendingPathComponent("integration"), userStartupDirectory: startup.path
    ))
    let status = root.appendingPathComponent("status")
    pane.startProcess(executable: "/bin/zsh", args: ["-i"], environment: integration.environment + [
        "TERM=xterm-256color", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin", "HISTFILE=",
        "SWIFTTERMINAL_EXIT_STATUS_FILE=\(status.path)"
    ], execName: nil, currentDirectory: root.path)
    let source = TerminalProofSource.statusFile(status, generation: pane.connectionGeneration)
    let driver = TerminalCommandDriver()
    let first = await driver.run("cd '\(startup.path)'\nexport QUICK_COMMAND_VALUE='你好'", in: pane,
        proofSource: source, timeout: 5, allowsInteractiveInput: true)
    #expect(first.exitStatus == 0)
    #expect(first.returnedToPrompt)

    let run = Task {
        await driver.run("printf 'Password:'; read -r reply; printf '\\nQUICK_INPUT=%s:%s\\n' \"$reply\" \"$QUICK_COMMAND_VALUE\"; pwd",
            in: pane, proofSource: source, timeout: 5, allowsInteractiveInput: true)
    }
    defer { run.cancel() }
    let terminal = try #require(pane.terminal)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var waitingForInput = false
    while ContinuousClock.now < deadline {
        let cursor = terminal.getCursorLocation()
        let row = max(0, TerminalRunReading.lineCount(terminal) - terminal.getDims().rows) + cursor.y
        if TerminalRunReading.lineText(terminal, row: row)?.trimmingCharacters(in: .whitespaces) == "Password:" {
            waitingForInput = true
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(waitingForInput)
    // Let the driver's password detection run before supplying the user's input.
    try await Task.sleep(for: .milliseconds(160))
    pane.sendAIDispatch(Array("manual-reply\r".utf8)[...])
    let result = await run.value
    #expect(!result.timedOut)
    #expect(result.exitStatus == 0)
    #expect(result.returnedToPrompt)
    #expect(result.output.contains("QUICK_INPUT=manual-reply:你好"))
    #expect(result.output.replacingOccurrences(of: "\n", with: "").contains(startup.resolvingSymlinksInPath().path))
}
