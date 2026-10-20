import AppKit
import Darwin
import Foundation
import Testing
import SwiftTerm
@testable import SwiftTerminal

@MainActor
private func makeSSHFixturePane(
    home: URL,
    shell: String
) -> TerminalPaneView {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    let generation = pane.connectionGeneration
    pane.installProcessDelegate()
    let remoteCommand = SSHRemoteLaunch.remoteCommand(shell: shell, generation: pane.connectionGeneration)
    let environment = [
        "HOME=\(home.path)",
        "TERM=xterm-256color",
        "LANG=en_US.UTF-8",
        "PATH=/usr/bin:/bin",
        "SWIFTTERMINAL_CONNECTION_GENERATION=\(generation.uuidString.lowercased())"
    ]
    if shell == "zsh" {
        // sshd runs the command with the user's login shell; zsh command strings
        // are POSIX-sh compatible, so /bin/bash -c mirrors the remote flow.
        pane.startProcess(executable: "/bin/bash", args: ["-c", remoteCommand],
                          environment: environment, execName: nil, currentDirectory: home.path)
    } else {
        pane.startProcess(executable: "/bin/bash", args: ["-c", remoteCommand],
                          environment: environment, execName: nil, currentDirectory: home.path)
    }
    return pane
}

@MainActor
private func waitUntilReady(_ pane: TerminalPaneView, generation: UUID) async -> String? {
    let expected = "__SWIFTTERMINAL_READY=\(generation.uuidString.lowercased())"
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    var lastProblem: String?
    var settledSince: ContinuousClock.Instant?
    while ContinuousClock.now < deadline {
        if pane.proofBox.currentTitle == expected, let terminal = pane.terminal {
            // The READY title is printed before the prompt's OSC 133 marks
            // (PROMPT_COMMAND runs ahead of PS1), and zsh flushes PROMPT before
            // it draws RPROMPT — so early observations are transient in both
            // directions. Require a nil problem to hold for 250ms before
            // accepting readiness; report the last observed problem on timeout.
            let problem = TerminalRunReading.readinessProblem(
                terminal: terminal,
                title: pane.proofBox.currentTitle,
                generation: pane.connectionGeneration,
                userTypedSincePrompt: pane.proofBox.hasUserTypedSincePrompt)
            if problem == nil {
                if let since = settledSince,
                   ContinuousClock.now - since >= .milliseconds(250) { return nil }
                if settledSince == nil { settledSince = .now }
            } else {
                settledSince = nil
                lastProblem = problem
            }
        } else {
            settledSince = nil
        }
        try? await Task.sleep(for: .milliseconds(40))
    }
    if let lastProblem { return "TIMEOUT: \(lastProblem)" }
    return "TIMEOUT: title=\(pane.proofBox.currentTitle), expected=\(expected)"
}

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("SSHReady-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@Test("SSH bash readiness with a two-line PS1", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshBashTwoLinePrompt() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("# fixture\nPS1='\\u@\\h:\\w\\n\\$ '\n".utf8)
        .write(to: home.appendingPathComponent(".bashrc"))
    let pane = makeSSHFixturePane(home: home, shell: "bash")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "bash two-line PS1 readiness problem: \(problem ?? "-")")
}

@Test("SSH bash readiness with a prompt that ends in a newline", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshBashPromptWithTrailingNewline() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("# fixture\\nPS1='\\u@\\h:\\w\\$ '\\n".utf8)
        .write(to: home.appendingPathComponent(".bashrc"))
    let pane = makeSSHFixturePane(home: home, shell: "bash")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "bash trailing-newline PS1 readiness problem: \(problem ?? "-")")
}

@Test("SSH zsh readiness with a two-line PROMPT", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshZshTwoLinePrompt() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("# fixture\nPROMPT='%n@host %~'$'\\n'%# '\n".utf8)
        .write(to: home.appendingPathComponent(".zshrc"))
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "zsh two-line PROMPT readiness problem: \(problem ?? "-")")
}

@Test("SSH bash readiness after a completed command", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshBashReadinessAfterCommand() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("# fixture\nPS1='\\u@\\h:\\w\\n\\$ '\n".utf8)
        .write(to: home.appendingPathComponent(".bashrc"))
    let pane = makeSSHFixturePane(home: home, shell: "bash")
    defer { if pane.process?.running == true { pane.terminate() } }
    var problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "initial readiness problem: \(problem ?? "-")")
    guard problem == nil else { return }
    let driver = TerminalCommandDriver()
    let first = await driver.run("printf 'STEP1\\n'", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 8)
    #expect(!first.unavailable, "first run refused: \(first.unavailableReason ?? "-")")
    guard !first.unavailable else { return }
    if let terminal = pane.terminal {
        problem = TerminalRunReading.readinessProblem(
            terminal: terminal,
            title: pane.proofBox.currentTitle,
            generation: pane.connectionGeneration,
            userTypedSincePrompt: pane.proofBox.hasUserTypedSincePrompt)
        #expect(problem == nil, "post-command readiness problem: \(problem ?? "-")")
    }
}

@Test("SSH bash readiness with a single-line PS1 (control)", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshBashSingleLinePrompt() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("# fixture\\nPS1='\\u@\\h:\\w\\$ '\\n".utf8)
        .write(to: home.appendingPathComponent(".bashrc"))
    let pane = makeSSHFixturePane(home: home, shell: "bash")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "bash single-line PS1 readiness problem: \(problem ?? "-")")
}

@Test("SSH bash readiness when the prompt moves the cursor with CSI instead of LF", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshBashPromptWithCursorDownSequence() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // PS1 line break done with a cursor-down escape (no LF), like prompt
    // frameworks that draw multi-line frames with cursor positioning.
    try Data("# fixture\nPS1='head\\[\\e[1B\\]\\$ '\n".utf8)
        .write(to: home.appendingPathComponent(".bashrc"))
    let pane = makeSSHFixturePane(home: home, shell: "bash")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "bash CSI cursor-down PS1 readiness problem: \(problem ?? "-")")
}

@Test("SSH zsh readiness with an RPROMPT printed after the B marker", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshZshReadinessWithRPROMPT() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // RPROMPT is drawn after PROMPT (after our OSC 133 B marker) at the right
    // margin; SwiftTerm tags those cells as input even though nothing is typed.
    // zsh only draws RPROMPT when it fits, so keep PROMPT short here.
    try Data("# fixture\nPROMPT='> '\nRPROMPT='[R]'\n".utf8)
        .write(to: home.appendingPathComponent(".zshrc"))
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "zsh RPROMPT readiness problem: \(problem ?? "-")")
}

@Test("SSH zsh readiness with a two-line PROMPT and an RPROMPT", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshZshTwoLinePromptWithRPROMPT() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // RPROMPT is drawn on the first prompt line; cursor waits on the second.
    try Data("# fixture\nPROMPT='top'$'\n'%# '\nRPROMPT='[R]'\n".utf8)
        .write(to: home.appendingPathComponent(".zshrc"))
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "zsh two-line PROMPT + RPROMPT readiness problem: \(problem ?? "-")")
}

@Test("Real typed but unsubmitted text still blocks readiness", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshZshUnsubmittedTypingBlocksReadiness() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let ready = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(ready == nil)
    guard ready == nil, let terminal = pane.terminal else { return }
    pane.send(data: Array("echo half".utf8)[...])
    try await Task.sleep(for: .milliseconds(300))
    #expect(pane.proofBox.hasUserTypedSincePrompt, "pane.send must mark user typing")
    let problem = TerminalRunReading.readinessProblem(
        terminal: terminal,
        title: pane.proofBox.currentTitle,
        generation: pane.connectionGeneration,
        userTypedSincePrompt: pane.proofBox.hasUserTypedSincePrompt)
    #expect(problem?.contains("未提交") == true, "expected pending-input block, got: \(problem ?? "nil")")
    // The next prompt's READY title clears the marker for a fresh cycle.
    pane.receivedTitle("__SWIFTTERMINAL_READY=\(pane.connectionGeneration.uuidString.lowercased())")
    #expect(!pane.proofBox.hasUserTypedSincePrompt, "READY must reset the user-typed marker")
}

@Test("SSH zsh readiness survives a ZLE prompt redraw after resize", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sshZshReadinessAfterWindowResizeRedraw() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let zshrc = """
        # fixture
        PROMPT=$'top\\n%# '
        RPROMPT='[R]'
        zle-line-init() { zle reset-prompt }
        zle -N zle-line-init
        """
    try Data(zshrc.utf8).write(to: home.appendingPathComponent(".zshrc"))
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "pre-resize readiness problem: \(problem ?? "-")")
    guard problem == nil else { return }
    // Resize the PTY: SIGWINCH makes zsh redraw the whole prompt while the
    // semantic state is already armed, so the redrawn prompt text is tagged
    // as input. Readiness must still hold with nothing typed.
    // No window in this test harness: the font must be set first so the view
    // can compute cell dimensions, then a frame change propagates through
    // processSizeChange -> TIOCSWINSZ (kernel raises SIGWINCH) -> ZLE redraw.
    pane.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    pane.setFrameSize(NSSize(width: 960, height: 600))
    try await Task.sleep(for: .milliseconds(600))
    let driver = TerminalCommandDriver()
    let probe = await driver.run("echo COLS=$COLUMNS", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 5)
    if ProcessInfo.processInfo.environment["AI_DUMP"] == "1" {
        try? "PROBE=[\(probe.output)] unavailable=\(probe.unavailable) reason=\(probe.unavailableReason ?? "-")\n"
            .write(toFile: "/tmp/ssh-probe.txt", atomically: true, encoding: .utf8)
        if let t = pane.terminal {
            try? "DIMS=\(t.getDims().cols)x\(t.getDims().rows)\n".write(toFile: "/tmp/ssh-probe.txt", atomically: true, encoding: .utf8)
        }
    }
    guard let terminal = pane.terminal else { return }
    if ProcessInfo.processInfo.environment["AI_DUMP"] == "1" {
        var dump = ""
        let count = TerminalRunReading.lineCount(terminal)
        for row in max(0, count - terminal.getDims().rows)..<count {
            guard let line = terminal.bufferLine(atRow: row) else { continue }
            var roles = ""
            var text = ""
            for col in 0..<terminal.getDims().cols {
                let c = line[col].getCharacter()
                text.append(c == "\0" ? " " : c)
                switch terminal.semanticContent(at: Position(col: col, row: row)) {
                case nil, .some(.none): roles.append(".")
                case .some(.prompt): roles.append("P")
                case .some(.input): roles.append("I")
                case .some(.output): roles.append("O")
                }
            }
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { dump.append("ROW \(row) KIND=\(String(describing: terminal.semanticRowKind(at: row))) [\(t)] \(roles)\n") }
        }
        let cur = terminal.getCursorLocation()
        dump.append("CURSOR y=\(cur.y) x=\(cur.x) origin=\(String(describing: terminal.activeSemanticPromptOrigin))\n")
        try? dump.write(toFile: "/tmp/ssh-dump.txt", atomically: true, encoding: .utf8)
    }
    let afterResize = TerminalRunReading.readinessProblem(
        terminal: terminal,
        title: pane.proofBox.currentTitle,
        generation: pane.connectionGeneration,
        userTypedSincePrompt: pane.proofBox.hasUserTypedSincePrompt)
    #expect(afterResize == nil, "post-resize readiness problem: \(afterResize ?? "nil")")
}

@Test("Terminal-initiated responses and focus reports are not human typing", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func terminalResponsesDoNotMarkUserTyping() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // Prompt frameworks (p10k and friends) query the terminal after the
    // prompt appears and read the responses; focus changes report as well.
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil, "pre-response readiness problem: \(problem ?? "-")")
    guard problem == nil, let terminal = pane.terminal else { return }
    #expect(!pane.proofBox.hasUserTypedSincePrompt)
    terminal.sendResponse(text: "\u{1b}[?1;2c")
    terminal.setTerminalFocus(false)
    terminal.setTerminalFocus(true)
    #expect(!pane.proofBox.hasUserTypedSincePrompt,
        "terminal responses/focus reports must not count as typing")
    // The AI readiness scan must stay gated off after all of that.
    let after = TerminalRunReading.readinessProblem(
        terminal: terminal,
        title: pane.proofBox.currentTitle,
        generation: pane.connectionGeneration,
        userTypedSincePrompt: pane.proofBox.hasUserTypedSincePrompt)
    #expect(after == nil, "readiness problem after responses: \(after ?? "-")")
}

@Test("AI keeps working in a sudo -i style child shell without hooks", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sudoChildShellFallbackMode() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil)
    guard problem == nil else { return }
    let driver = TerminalCommandDriver()
    // Replace the shell with an integration-free bash, exactly like `sudo -i`
    // does (no OSC 133 hooks, stale BUSY title). The proof never arrives, so
    // the first run legitimately times out.
    let execRun = await driver.run("exec /bin/bash --noprofile --norc -i", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 6)
    #expect(execRun.timedOut)
    guard execRun.timedOut else { return }
    try await Task.sleep(for: .milliseconds(400))
    // The AI must now work through the self-proving fallback payload.
    let root = await driver.run("printf 'ROOT_OK'", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 8)
    #expect(!root.unavailable, "fallback refused: \(root.unavailableReason ?? "-")")
    if ProcessInfo.processInfo.environment["AI_DUMP"] == "1" {
        var dump = "TITLE=[\(pane.proofBox.currentTitle)]\n"
        if let t = pane.terminal {
            let count = TerminalRunReading.lineCount(t)
            for row in max(0, count - t.getDims().rows)..<count {
                if let line = TerminalRunReading.lineText(t, row: row) {
                    dump.append("ROW \(row): [\(line.replacingOccurrences(of: "\u{1B}", with: "<ESC>"))]\n")
                }
            }
        }
        try? dump.write(toFile: "/tmp/ssh-dump.txt", atomically: true, encoding: .utf8)
    }
    #expect(!root.timedOut)
    #expect(root.exitStatus == 0)
    #expect(root.returnedToPrompt)
    #expect(root.output.contains("ROOT_OK"))
    // Unsubmitted typing must still block in fallback mode.
    pane.send(data: Array("echo half".utf8)[...])
    try await Task.sleep(for: .milliseconds(300))
    #expect(pane.proofBox.hasUserTypedSincePrompt)
    if let terminal = pane.terminal {
        let blocked = TerminalRunReading.unmarkedShellReadinessProblem(
            terminal: terminal,
            title: pane.proofBox.currentTitle,
            userTypedSincePrompt: pane.proofBox.hasUserTypedSincePrompt)
        #expect(blocked?.contains("未提交") == true, "expected typing block, got: \(blocked ?? "nil")")
    }
}

@Test("A terminal command that never finishes is bounded and interrupted", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func neverFinishingCommandIsBounded() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil)
    guard problem == nil else { return }
    let driver = TerminalCommandDriver()
    // `read` waits for stdin forever: the proof never arrives, the driver
    // must stop at its timeout, interrupt, and hand back a usable session.
    let result = await driver.run("read __swiftterminal_x", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 3)
    #expect(!result.unavailable)
    #expect(result.timedOut)
    let reuse = await driver.run("printf 'SESSION_REUSABLE'", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 8)
    #expect(!reuse.unavailable, "reuse refused: \(reuse.unavailableReason ?? "-")")
    #expect(reuse.exitStatus == 0)
    #expect(reuse.output.contains("SESSION_REUSABLE"))
}

@Test("A command waiting at a sudo password prompt is interrupted quickly", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func sudoPasswordPromptInterruptsFast() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil)
    guard problem == nil else { return }
    let driver = TerminalCommandDriver()
    let started = ContinuousClock.now
    let result = await driver.run("sudo -v", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 30,
        requiresSudoPassword: true, sudoPasswordProvider: nil)
    let elapsed = ContinuousClock.now - started
    #expect(result.timedOut)
    #expect(result.interruptedReason?.contains("密码") == true,
        "expected password-prompt interrupt, got: \(result.interruptedReason ?? "nil")")
    #expect(elapsed < .seconds(8), "password prompts must fail fast, took \(elapsed)")
    let reuse = await driver.run("printf 'STILL_USABLE'", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 8)
    #expect(!reuse.unavailable)
    #expect(reuse.output.contains("STILL_USABLE"))
}

@Test("A stored task sudo password is fed to a waiting password prompt", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func storedSudoPasswordIsFedToPrompt() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // bash: `read -rs -p` prints the prompt silently and hides the input.
    let pane = makeSSHFixturePane(home: home, shell: "bash")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil)
    guard problem == nil else { return }
    let driver = TerminalCommandDriver()
    let result = await driver.run(
        "read -rs -p 'Password: ' __swiftterminal_x; printf 'LEN:%s' \"${#__swiftterminal_x}\"",
        in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 10,
        requiresSudoPassword: true, sudoPasswordProvider: { "sekret" })
    #expect(!result.unavailable, "refused: \(result.unavailableReason ?? "-")")
    #expect(!result.timedOut)
    #expect(result.exitStatus == 0)
    #expect(result.output.contains("LEN:6"), "password length must reach the prompt: \(result.output)")
    #expect(!result.output.contains("sekret"), "the password itself must never be echoed")
}

@Test("Two password prompts are fed two different stored passwords", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func twoPasswordPromptsGetTwoPasswords() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let pane = makeSSHFixturePane(home: home, shell: "bash")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil)
    guard problem == nil else { return }
    final class Passwords {
        var list = ["aaa", "bbb"]
        func next() -> String? { list.isEmpty ? nil : list.removeFirst() }
    }
    let passwords = Passwords()
    let driver = TerminalCommandDriver()
    let result = await driver.run(
        "read -rs -p 'Password: ' __a; read -rs -p 'Password: ' __b; printf 'LEN:%s-%s' \"${#__a}\" \"${#__b}\"",
        in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 10,
        requiresSudoPassword: true, sudoPasswordProvider: { passwords.next() })
    #expect(!result.unavailable, "refused: \(result.unavailableReason ?? "-")")
    #expect(!result.timedOut)
    #expect(result.exitStatus == 0)
    #expect(result.output.contains("LEN:3-3"), "both passwords must reach their prompts: \(result.output)")
    #expect(!result.output.contains("aaa") && !result.output.contains("bbb"))
}

@Test("A silently hung command is interrupted after the idle threshold", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func silentHangIsInterruptedAtIdleLimit() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil)
    guard problem == nil else { return }
    let driver = TerminalCommandDriver()
    let started = ContinuousClock.now
    let result = await driver.run("sleep 30", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 20)
    let elapsed = ContinuousClock.now - started
    #expect(result.timedOut)
    #expect(result.interruptedReason?.contains("没有任何输出") == true,
        "expected idle interrupt, got: \(result.interruptedReason ?? "nil")")
    #expect(elapsed < .seconds(15), "idle interrupt must fire before the total timeout, took \(elapsed)")
}

@Test("Intermittent output keeps a slow command alive across idle gaps", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func intermittentOutputKeepsCommandAlive() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let pane = makeSSHFixturePane(home: home, shell: "zsh")
    defer { if pane.process?.running == true { pane.terminate() } }
    let problem = await waitUntilReady(pane, generation: pane.connectionGeneration)
    #expect(problem == nil)
    guard problem == nil else { return }
    let driver = TerminalCommandDriver()
    // Three 6-second silent gaps: under the 8s idle limit, but the total run
    // (12s) exceeds it. Output activity between gaps must keep it alive.
    let result = await driver.run("echo t0; sleep 6; echo t1; sleep 6; echo t2", in: pane,
        proofSource: .title(generation: pane.connectionGeneration), timeout: 20)
    #expect(!result.unavailable)
    #expect(!result.timedOut, "output activity must extend the wait: \(result.interruptedReason ?? "-")")
    #expect(result.exitStatus == 0)
    #expect(result.output.contains("t2"))
}
