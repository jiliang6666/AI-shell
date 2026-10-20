import AppKit
import Darwin
import Foundation
import Testing
@testable import SwiftTerminal

@Test("A multiline command cannot complete before its body finishes, and preserves the real exit status", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"), arguments: [false, true])
@MainActor
func terminalDriverWaitsForCommandBody(_ useTitleProof: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalProofBoundary-\(UUID())")
    let startup = root.appendingPathComponent("user-startup")
    try FileManager.default.createDirectory(at: startup, withIntermediateDirectories: true)
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    defer {
        if pane.process?.running == true { pane.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    pane.installProcessDelegate()
    let integration = try #require(ZshShellIntegration.prepare(generation: pane.connectionGeneration,
        directory: root.appendingPathComponent("integration"), userStartupDirectory: startup.path))
    let status = root.appendingPathComponent("status")
    let environment = integration.environment + ["TERM=xterm-256color", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin", "HISTFILE=", "SWIFTTERMINAL_EXIT_STATUS_FILE=\(status.path)"]
    pane.startProcess(executable: "/bin/zsh", args: ["-i"], environment: environment, execName: nil, currentDirectory: root.path)
    let source: TerminalProofSource = useTitleProof ? .title(generation: pane.connectionGeneration)
        : .statusFile(status, generation: pane.connectionGeneration)
    let driver = TerminalCommandDriver()
    let started = root.appendingPathComponent("started")
    let gate = root.appendingPathComponent("release")
    var completed = false
    let run = Task {
        let result = await driver.run("""
        /usr/bin/touch '\(started.path)'
        while [[ ! -e '\(gate.path)' ]]; do /bin/sleep 0.02; done
        printf 'BODY_FINISHED\\n'
        (exit 7)
        """, in: pane, proofSource: source, timeout: 5)
        completed = true
        return result
    }
    defer { run.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FileManager.default.fileExists(atPath: started.path))
    var queuedCompleted = false
    let queued = Task {
        let result = await driver.run("printf 'QUEUED_FINISHED\\n'", in: pane, proofSource: source, timeout: 5)
        queuedCompleted = true
        return result
    }
    defer { queued.cancel() }
    // Give the driver's proof polling a chance to see any premature proof.
    try await Task.sleep(for: .milliseconds(180))
    #expect(!completed, "The body is still blocked on the fixture gate")
    #expect(!queuedCompleted, "The second run must wait for this shell's first command")
    try Data().write(to: gate)
    let result = await run.value
    #expect(!result.unavailable)
    #expect(!result.timedOut)
    #expect(result.exitStatus == 7)
    #expect(result.returnedToPrompt)
    #expect(result.output.contains("BODY_FINISHED"))
    let queuedResult = await queued.value
    #expect(queuedResult.exitStatus == 0)
    #expect(queuedResult.returnedToPrompt)
    #expect(queuedResult.output.contains("QUEUED_FINISHED"))
    guard result.exitStatus == 7, result.returnedToPrompt else { return }
    let next = await driver.run("cd '\(startup.path)'\ncat <<'END'\nit's ready\nEND\npwd", in: pane, proofSource: source, timeout: 5)
    #expect(next.exitStatus == 0)
    #expect(next.returnedToPrompt)
    #expect(next.output.contains("it's ready"))
    #expect(next.output.replacingOccurrences(of: "\n", with: "").contains(startup.resolvingSymlinksInPath().path))
    let reuse = await driver.run("pwd", in: pane, proofSource: source, timeout: 5)
    #expect(reuse.output.replacingOccurrences(of: "\n", with: "").contains(startup.resolvingSymlinksInPath().path))
}

@Test("Local zsh PTY runs through the real driver and rolls back its shell integration", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func localTerminalPTYExecutionAndRollback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalPTYFixture-\(UUID())")
    let startup = root.appendingPathComponent("user-startup")
    try FileManager.default.createDirectory(at: startup, withIntermediateDirectories: true)
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    defer {
        if pane.process?.running == true { pane.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    var exitNoticeReceived = false
    pane.installProcessDelegate { _ in exitNoticeReceived = true }
    #expect(pane.processDelegate != nil)
    let integration = try #require(ZshShellIntegration.prepare(generation: pane.connectionGeneration,
        directory: root.appendingPathComponent("integration"), userStartupDirectory: startup.path))
    let status = root.appendingPathComponent("status")
    let environment = integration.environment + ["TERM=xterm-256color", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin", "HISTFILE=", "SWIFTTERMINAL_EXIT_STATUS_FILE=\(status.path)"]
    pane.startProcess(executable: "/bin/zsh", args: ["-i"], environment: environment, execName: nil, currentDirectory: root.path)
    let source = TerminalProofSource.statusFile(status, generation: pane.connectionGeneration)
    let driver = TerminalCommandDriver()
    let first = await driver.run("pwd\nprintf 'LOCAL_PTY_OK\\n'", in: pane, proofSource: source, timeout: 5)
    #expect(!first.unavailable)
    #expect(!first.timedOut)
    #expect(first.returnedToPrompt)
    #expect(first.exitStatus == 0)
    #expect(first.output.contains("LOCAL_PTY_OK"))
    #expect(!first.output.contains("__swiftterminal_begin"))
    #expect(!first.output.contains("__SWIFTTERMINAL"))
    #expect(first.output.replacingOccurrences(of: "\n", with: "").contains(root.resolvingSymlinksInPath().path))
    let terminal = try #require(pane.terminal)
    let visibleTerminalText = (0..<TerminalRunReading.lineCount(terminal))
        .compactMap { TerminalRunReading.lineText(terminal, row: $0) }
        .joined(separator: "\n")
    #expect(visibleTerminalText.contains("pwd"), "The actual command should be visible in the shell")
    #expect(visibleTerminalText.contains("LOCAL_PTY_OK"), "The shell output should remain visible")
    #expect(!visibleTerminalText.contains("__swiftterminal_begin"))
    #expect(!visibleTerminalText.contains("builtin eval --"))
    #expect(!visibleTerminalText.contains("__SWIFTTERMINAL_STARTED="))
    let second = await driver.run("printf 'LOCAL_PTY_REUSE_OK\\n'", in: pane, proofSource: source, timeout: 5)
    #expect(second.exitStatus == 0)
    #expect(second.returnedToPrompt)
    #expect(second.output.contains("LOCAL_PTY_REUSE_OK"),
        "diag: unavailable=\(second.unavailable) reason=\(second.unavailableReason ?? "-") timedOut=\(second.timedOut) exit=\(second.exitStatus.map(String.init) ?? "nil") returned=\(second.returnedToPrompt) output=[\(second.output.prefix(300))]")
    let pid = try #require(pane.process?.shellPid)
    pane.send(data: Array("exit\r".utf8)[...])
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(kill(pid, 0) != 0)
    #expect(exitNoticeReceived)
    try FileManager.default.removeItem(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test("A shell without integration refuses AI auto-input while manual input keeps working", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_LOCAL_PTY_TESTS"] == "1"))
@MainActor
func noIntegrationShellRejectsAIAutoInputAndKeepsManualInput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalNoIntegration-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    defer {
        if pane.process?.running == true { pane.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    pane.startProcess(executable: "/bin/zsh", args: ["-i"],
        environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin", "HISTFILE="],
        execName: nil, currentDirectory: root.path)
    try await Task.sleep(for: .milliseconds(500))
    let driver = TerminalCommandDriver()
    let outcome = await driver.run("printf 'NO_AI_INPUT_LEAK\\n'", in: pane,
        proofSource: .unavailable(generation: pane.connectionGeneration), timeout: 2)
    #expect(outcome.unavailable)
    #expect(!outcome.returnedToPrompt)
    let terminal = try #require(pane.terminal)
    var leaked = false
    for row in 0..<TerminalRunReading.lineCount(terminal) {
        if TerminalRunReading.lineText(terminal, row: row)?.contains("NO_AI_INPUT_LEAK") == true { leaked = true }
    }
    #expect(!leaked)

    pane.send(data: Array("printf 'MANUAL_INPUT_OK\\n'\r".utf8)[...])
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var manualEcho = false
    while ContinuousClock.now < deadline && !manualEcho {
        try await Task.sleep(for: .milliseconds(60))
        for row in 0..<TerminalRunReading.lineCount(terminal) {
            if TerminalRunReading.lineText(terminal, row: row)?.contains("MANUAL_INPUT_OK") == true { manualEcho = true }
        }
    }
    #expect(manualEcho)
    try FileManager.default.removeItem(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test("Isolated SSH bash and zsh sessions complete driver commands without touching remote startup files", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_SSH_TESTS"] == "1"))
@MainActor
func isolatedSSHDriverCompletionForBashAndZsh() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TerminalSSHFixture-\(UUID().uuidString)", isDirectory: true)
    let etc = root.appendingPathComponent("etc")
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let port = Int.random(in: 20_000...60_000)

    func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SSHFixture", code: Int(process.terminationStatus))
        }
    }
    try run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-q", "-f", etc.appendingPathComponent("host_ed25519").path])
    try run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-q", "-f", home.appendingPathComponent("client_ed25519").path])
    try FileManager.default.copyItem(at: home.appendingPathComponent("client_ed25519.pub"), to: home.appendingPathComponent("authorized_keys"))
    let config = """
    Port \(port)
    ListenAddress 127.0.0.1
    HostKey \(etc.appendingPathComponent("host_ed25519").path)
    PidFile \(etc.appendingPathComponent("sshd.pid").path)
    PasswordAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile \(home.appendingPathComponent("authorized_keys").path)
    UsePAM no
    StrictModes no
    LogLevel ERROR
    """
    try Data(config.utf8).write(to: etc.appendingPathComponent("sshd_config"))

    let userHomeStartupFiles = [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile"]
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    func startupHashes() throws -> [String: Data] {
        var hashes: [String: Data] = [:]
        for file in userHomeStartupFiles {
            let url = homeDirectory.appendingPathComponent(file)
            hashes[file] = (try? Data(contentsOf: url)) ?? Data()
        }
        return hashes
    }
    let startupBefore = try startupHashes()

    let sshd = Process()
    sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    sshd.arguments = ["-D", "-f", etc.appendingPathComponent("sshd_config").path, "-E", etc.appendingPathComponent("sshd.log").path]
    try sshd.run()
    defer {
        sshd.terminate()
        sshd.waitUntilExit()
        if sshd.isRunning {
            kill(sshd.processIdentifier, SIGKILL)
            sshd.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }
    var listening = false
    for _ in 0..<50 {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
        close(descriptor)
        if connected { listening = true; break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(listening)

    let username = NSUserName()
    for remoteShell in ["zsh", "bash"] {
        let host = SSHHost(name: "隔离\(remoteShell)", address: "127.0.0.1", username: username, port: port,
            authentication: .privateKey, privateKeyPath: home.appendingPathComponent("client_ed25519").path,
            remoteShell: remoteShell)
        let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        pane.installProcessDelegate(onExit: nil)
        let plan = SSHRemoteLaunch.plan(for: host, generation: pane.connectionGeneration, extraOptions: [
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"
        ])
        #expect(plan.proofSource.supportsCompletionProof)
        let environment = ["TERM=xterm-256color", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin",
            "HOME=\(homeDirectory.path)", "USER=\(username)"]
        _ = NSApplication.shared
        let fixtureWindow = NSWindow(contentRect: pane.frame, styleMask: .borderless, backing: .buffered, defer: false)
        fixtureWindow.contentView = pane
        defer { fixtureWindow.contentView = nil; pane.stopForRemoval() }
        var connectionStates: [SSHConnectionState] = []
        let (stateStream, stateContinuation) = AsyncStream<SSHConnectionState>.makeStream()
        pane.prepareSSH(host, environment: environment, onState: {
            connectionStates.append($0)
            stateContinuation.yield($0)
        }, extraOptions: [
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"
        ])
        let startupTimeout = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            stateContinuation.finish()
        }
        defer { startupTimeout.cancel(); stateContinuation.finish() }
        var connected = false
        for await state in stateStream {
            if state == .connected { connected = true; break }
            if state.canRetry { break }
        }
        startupTimeout.cancel()
        try #require(connected, "The prepared SSH session must reach a prompt before driver input")
        let driver = TerminalCommandDriver()
        let marker = "SSH_\(remoteShell.uppercased())_OK"
        let first = await driver.run("pwd\nprintf '\(marker)\\n'", in: pane,
            proofSource: plan.proofSource, timeout: 20)
        #expect(!first.unavailable)
        #expect(!first.timedOut)
        #expect(first.returnedToPrompt)
        #expect(first.exitStatus == 0)
        #expect(first.output.contains(marker))
        #expect(!first.output.contains("__swiftterminal_begin"))
        #expect(!first.output.contains("__SWIFTTERMINAL"))
        #expect(connectionStates.first == .connecting)
        #expect(connectionStates.contains(.connected))
        let shellVersion = await driver.run("printf 'SHELL=%s\\n' \"${ZSH_VERSION:-$BASH_VERSION}\"", in: pane,
            proofSource: plan.proofSource, timeout: 10)
        #expect(shellVersion.exitStatus == 0)
        #expect(shellVersion.output.contains("SHELL=") && !shellVersion.output.contains("SHELL=\n"))
        let nonzero = await driver.run("/bin/sleep 0.2\nprintf 'SSH_BODY_FINISHED\\n'\n(exit 7)", in: pane,
            proofSource: plan.proofSource, timeout: 10)
        #expect(nonzero.exitStatus == 7)
        #expect(nonzero.returnedToPrompt)
        #expect(nonzero.output.contains("SSH_BODY_FINISHED"))
        let multiline = await driver.run("cd '\(home.path)'\ncat <<'END'\nit's ready\nEND\npwd", in: pane,
            proofSource: plan.proofSource, timeout: 10)
        #expect(multiline.exitStatus == 0)
        #expect(multiline.returnedToPrompt)
        #expect(multiline.output.contains("it's ready"))
        #expect(multiline.output.replacingOccurrences(of: "\n", with: "").contains(home.resolvingSymlinksInPath().path))
        let second = await driver.run("printf 'SSH_REUSE_OK\\n'", in: pane,
            proofSource: plan.proofSource, timeout: 10)
        #expect(second.exitStatus == 0)
        let noNewline = await driver.run("printf 'NO_NEWLINE'", in: pane, proofSource: plan.proofSource, timeout: 10)
        #expect(noNewline.exitStatus == 0)
        #expect(noNewline.output == "NO_NEWLINE")
        #expect(second.returnedToPrompt)
        #expect(second.output.contains("SSH_REUSE_OK"))
        let pid = try #require(pane.process?.shellPid)
        pane.send(data: Array("exit\r".utf8)[...])
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while kill(pid, 0) == 0 && ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(pid, 0) != 0)
        #expect(connectionStates.last == .disconnected)
        fixtureWindow.contentView = nil
        pane.stopForRemoval()
    }
    let startupAfter = try startupHashes()
    #expect(startupAfter == startupBefore)
    try FileManager.default.removeItem(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test("SSH zsh marks the active prompt as editable for click-to-position")
@MainActor
func sshZshPromptMarksEditableInput() throws {
    let host = SSHHost(name: "Click Fixture", address: "ssh.example.com", username: "deploy", remoteShell: "zsh")
    let plan = SSHRemoteLaunch.plan(for: host, generation: UUID())
    let remoteCommand = try #require(plan.arguments.last)
    let payload = try #require(remoteCommand
        .components(separatedBy: "printf %s ")
        .last?
        .components(separatedBy: " | ")
        .first)
    let hookData = try #require(Data(base64Encoded: payload))
    let hooks = try #require(String(data: hookData, encoding: .utf8))

    #expect(hooks.contains("\\e]133;A;cl=line\\a"))
    #expect(hooks.contains("\\e]133;B\\a"))
    #expect(hooks.contains("\\e]133;C\\a"))
}

@Test("Local zsh integration keeps prompt markers as terminal escape sequences")
@MainActor
func localZshIntegrationMarksEditablePrompt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZshClickIntegration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("user"), withIntermediateDirectories: true)

    let integration = try #require(ZshShellIntegration.prepare(
        generation: UUID(),
        directory: root.appendingPathComponent("integration"),
        userStartupDirectory: root.appendingPathComponent("user").path
    ))
    let zshrc = try String(contentsOf: integration.directory.appendingPathComponent(".zshrc"), encoding: .utf8)

    #expect(zshrc.contains(#"\e]133;A;cl=line\a"#))
    #expect(zshrc.contains(#"\e]133;B\a"#))
    #expect(!zshrc.contains(#"\\e]133;A"#))
    #expect(!zshrc.contains(#"\\e]133;B"#))
}
