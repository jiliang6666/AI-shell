import Foundation
import Testing
@testable import SwiftTerminal

@Test("Terminal exit status is read from the shell's status file")
func terminalExitStatusParsing() {
    #expect(TerminalRunReading.exitStatus(fromStatusFile: "0") == 0)
    #expect(TerminalRunReading.exitStatus(fromStatusFile: "1\n") == 1)
    #expect(TerminalRunReading.exitStatus(fromStatusFile: "-9") == -9)
    #expect(TerminalRunReading.exitStatus(fromStatusFile: "  127  ") == 127)
    #expect(TerminalRunReading.exitStatus(fromStatusFile: nil) == nil)
    #expect(TerminalRunReading.exitStatus(fromStatusFile: "") == nil)
    #expect(TerminalRunReading.exitStatus(fromStatusFile: "\n") == nil)
    #expect(TerminalRunReading.exitStatus(fromStatusFile: "command not found") == nil)
}

@Test("Unmarked continuation prompts cannot pass the shell-prompt heuristic")
func unmarkedContinuationPromptIsNotReady() {
    #expect(!TerminalRunReading.looksLikeUnmarkedShellPrompt(">"))
    #expect(!TerminalRunReading.looksLikeUnmarkedShellPrompt("user@host:~>"))
    #expect(TerminalRunReading.looksLikeUnmarkedShellPrompt("user@host:~$"))
    #expect(TerminalRunReading.looksLikeUnmarkedShellPrompt("root#"))
}

@Test("Terminal output keeps inner blank lines and drops screen padding")
func terminalOutputTrimming() {
    let text = TerminalRunReading.trimmedBlock([
        "total 8",
        "drwxr-xr-x  3 mac  staff   96 Sep 29 15:00 .",
        "",
        "second block",
        "   ",
        "",
        ""
    ])

    #expect(text == "total 8\ndrwxr-xr-x  3 mac  staff   96 Sep 29 15:00 .\n\nsecond block")
}

@Test("Oversized terminal output is clipped with a visible marker")
func terminalOutputClipping() {
    let short = TerminalRunReading.limitedOutput("ok", limit: 10)
    let long = TerminalRunReading.limitedOutput(String(repeating: "x", count: 40), limit: 10)

    #expect(short == "ok")
    #expect(long.hasPrefix(String(repeating: "x", count: 10)))
    #expect(long.contains("截断"))
}

@Test("Completion proof requires this call nonce and final status")
func terminalCompletionProofParsing() {
    #expect(TerminalRunReading.completion(fromStatusFile: "abc\n0") == TerminalCompletionProof(nonce: "abc", exitStatus: 0))
    #expect(TerminalRunReading.completion(fromStatusFile: "abc\n1\n")?.exitStatus == 1)
    #expect(TerminalRunReading.completion(fromStatusFile: "abc") == nil)
    #expect(TerminalRunReading.completion(fromStatusFile: nil) == nil)
    #expect(TerminalRunReading.completion(fromStatusFile: "0\n0")?.nonce == "0")
}

@Test("Command interruption requires a started marker for the same nonce")
func terminalStartedProofParsing() {
    #expect(TerminalRunReading.hasStarted(inStatusFile: "abc", nonce: "abc"))
    #expect(TerminalRunReading.hasStarted(inStatusFile: "abc\n", nonce: "abc"))
    #expect(!TerminalRunReading.hasStarted(inStatusFile: "other\n", nonce: "abc"))
    #expect(!TerminalRunReading.hasStarted(inStatusFile: nil, nonce: "abc"))
    #expect(TerminalRunReading.hasStarted(inTitle: "__SWIFTTERMINAL_STARTED=abc", nonce: "abc"))
    #expect(TerminalRunReading.hasStarted(inTitle: "__SWIFTTERMINAL_PROOF=abc;0", nonce: "abc"))
    #expect(!TerminalRunReading.hasStarted(inTitle: "__SWIFTTERMINAL_STARTED=old", nonce: "abc"))
}

@Test("Delivery modes name where a command ran")
func commandDeliveryLabels() {
    #expect(CommandDelivery.terminal.title == "终端内执行")
    #expect(CommandDelivery.background.title == "后台执行")
    #expect(CommandDelivery.terminal.note == "终端内执行")
    #expect(CommandDelivery.background.note == "独立进程执行")
    #expect(ProposedShellCommand(id: "1", command: "ls", purpose: "列出", targetName: "本机").delivery == .terminal)
}
