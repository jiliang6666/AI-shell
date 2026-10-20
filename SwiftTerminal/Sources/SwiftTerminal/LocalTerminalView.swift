import AppKit
import SwiftTerm
import SwiftUI

/// SwiftTerm pins its own `NSScroller` to the view's trailing edge. When macOS
/// is set to always show scroll bars, that renders as a permanent grey strip
/// inside the terminal, so the scroller is hidden here. Terminal scrolling
/// (trackpad, wheel, ⌥PageUp/⌥PageDown) is not affected.
final class TerminalPaneView: LocalProcessTerminalView {
    let proofBox = TerminalProofBox()
    let connectionGeneration = UUID()
    private var retainedProcessDelegate: TerminalProcessDelegateProxy?
    private var pendingLaunch: (() -> Void)?
    private var sshProgress: SSHConnectionProgress?
    private var sshStateChanged: ((SSHConnectionState) -> Void)?
    private var sshPreparation: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    func prepareSSH(_ host: SSHHost, environment: [String], onState: ((SSHConnectionState) -> Void)?, extraOptions: [String] = []) {
        sshProgress = SSHConnectionProgress(generation: connectionGeneration, expectsReadyMarker: ["bash", "zsh"].contains(host.remoteShell))
        sshStateChanged = onState
        onState?(.connecting)
        let generation = connectionGeneration
        sshPreparation = Task { [weak self] in
            // Give the navigation and connection indicator a chance to render.
            await Task.yield()
            guard !Task.isCancelled else { return }
            let plan = await Task.detached(priority: .userInitiated) {
                SSHRemoteLaunch.plan(for: host, generation: generation, extraOptions: extraOptions)
            }.value
            guard !Task.isCancelled, let self, self.sshProgress?.state.canRetry == false else { return }
            self.startWhenSized { [weak self] in
                guard let self else { return }
                self.startProcess(executable: "/usr/bin/ssh", args: plan.arguments,
                                  environment: environment + plan.environment, execName: "ssh")
                if self.process?.running != true {
                    self.sshProgress?.finish()
                    self.publishSSHState()
                }
            }
            self.sshPreparation = nil
        }
    }

    func cancelSSHConnection() {
        guard sshProgress?.state.canCancel == true else { return }
        sshPreparation?.cancel()
        sshPreparation = nil
        pendingLaunch = nil
        sshProgress?.cancel()
        publishSSHState()
        if process?.running == true { terminate() }
    }

    func stopForRemoval() {
        sshPreparation?.cancel()
        sshPreparation = nil
        pendingLaunch = nil
        sshStateChanged = nil
        if process?.running == true { terminate() }
    }

    private func publishSSHState() {
        if let state = sshProgress?.state { sshStateChanged?(state) }
    }

    func receivedTitle(_ title: String) {
        proofBox.update(title: title)
        if title == "__SWIFTTERMINAL_READY=\(connectionGeneration.uuidString.lowercased())" {
            proofBox.resetUserTyped()
            // A fresh prompt is the right moment to undo any OSC 10/11 color
            // override the shell left behind, so the configured palette wins.
            TerminalAppearanceApplier.reassertColors(
                AppPreferences.load().terminalAppearance, to: self)
        }
        let previous = sshProgress?.state
        sshProgress?.receiveTitle(title)
        if previous != sshProgress?.state { publishSSHState() }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let previous = sshProgress?.state
        sshProgress?.receive(String(decoding: slice, as: UTF8.self))
        if previous != sshProgress?.state { publishSSHState() }
        super.dataReceived(slice: slice)
    }

    func startWhenSized(_ launch: @escaping () -> Void) {
        pendingLaunch = launch
        startPendingProcessIfReady()
    }

    private func startPendingProcessIfReady() {
        guard window != nil, frame.width > 0, frame.height > 0,
              let launch = pendingLaunch else { return }
        pendingLaunch = nil
        launch()
    }

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI can temporarily lay out restored/background tabs at zero
        // size. Resizing the running PTY to a tiny screen can erase the prompt
        // marks before the tab becomes visible. Keep its last usable size.
        guard newSize.width > 0, newSize.height > 0 else { return }
        super.setFrameSize(newSize)
        startPendingProcessIfReady()
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self) ?? false
    }

    /// True while the AI driver is writing into the PTY, so its command echo
    /// is not mistaken for human typing.
    var aiDispatchInFlight = false

    /// True while a terminal-initiated send (device-attribute responses, focus
    /// reports, semantic click sequences) is being forwarded. Prompt
    /// frameworks like p10k query the terminal and read responses after the
    /// prompt appears; focus changes report too. None of that is human typing.
    var forwardingTerminalInitiatedSend = false

    func sendAIDispatch(_ data: ArraySlice<UInt8>) {
        aiDispatchInFlight = true
        defer { aiDispatchInFlight = false }
        terminal.sendUserInput(data)
    }

    /// Terminal-initiated traffic arrives through the TerminalDelegate hop.
    /// Forward it, but do not count it as typing.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        forwardingTerminalInitiatedSend = true
        defer { forwardingTerminalInitiatedSend = false }
        super.send(source: source, data: data)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !aiDispatchInFlight, !forwardingTerminalInitiatedSend {
            if data.contains(0x0D) {
                proofBox.markCommandSubmitted(generation: connectionGeneration)
            } else {
                proofBox.markUserTyped()
            }
        }
        super.send(source: source, data: data)
    }

    func installProcessDelegate(onExit: ((Int32?) -> Void)? = nil) {
        let relay = TerminalProcessDelegateProxy(pane: self)
        relay.onExit = onExit
        retainedProcessDelegate = relay
        processDelegate = relay
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        sshProgress?.finish()
        publishSSHState()
        super.processTerminated(source, exitCode: exitCode)
    }

    override func layout() {
        super.layout()
        hideScroller()
        // The first prompt must arrive after SwiftUI has given this pane its
        // actual screen dimensions; reflowing an already printed startup
        // prompt can discard its OSC 133 origin, especially in restored tabs.
        startPendingProcessIfReady()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The system switched light/dark: dynamic colors were baked into the
        // terminal as fixed values, so re-resolve them under the new
        // appearance right away.
        TerminalAppearanceApplier.reassertColors(
            AppPreferences.load().terminalAppearance, to: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideScroller()
        startPendingProcessIfReady()
        if window != nil, activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.window != nil else { return }
                self.reassertAppearanceOnActive()
            }
        }
    }

    @objc private func reassertAppearanceOnActive() {
        TerminalAppearanceApplier.reassertColors(
            AppPreferences.load().terminalAppearance, to: self)
    }

    private func hideScroller() {
        for subview in subviews where subview is NSScroller && !subview.isHidden {
            subview.isHidden = true
        }
    }
}

@MainActor
final class TerminalProcessDelegateProxy: @preconcurrency LocalProcessTerminalViewDelegate {
    weak var pane: TerminalPaneView?
    var onExit: ((Int32?) -> Void)?

    init(pane: TerminalPaneView) { self.pane = pane }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        pane?.receivedTitle(title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
}

final class TerminalProofBox: @unchecked Sendable {
    private let lock = NSLock()
    private var title = ""
    private var completionProofs: [String: TerminalCompletionProof] = [:]
    private var proofOrder: [String] = []
    private var startedEvents: [(sequence: Int, nonce: String)] = []
    private var startSequence = 0
    private var userTypedSincePrompt = false

    func update(title: String) {
        lock.lock()
        if let proof = TerminalRunReading.completion(fromTitle: title) {
            recordStartedNonce(proof.nonce)
            completionProofs[proof.nonce] = proof
            proofOrder.removeAll { $0 == proof.nonce }
            proofOrder.append(proof.nonce)
            if proofOrder.count > 64 {
                completionProofs.removeValue(forKey: proofOrder.removeFirst())
            }
        } else if title.hasPrefix("__SWIFTTERMINAL_STARTED=") {
            recordStartedNonce(String(title.dropFirst("__SWIFTTERMINAL_STARTED=".count)))
        }
        self.title = title
        lock.unlock()
    }

    private func recordStartedNonce(_ nonce: String) {
        guard !startedEvents.contains(where: { $0.nonce == nonce }) else { return }
        startSequence += 1
        startedEvents.append((sequence: startSequence, nonce: nonce))
        if startedEvents.count > 64 { startedEvents.removeFirst() }
    }

    var latestStartSequence: Int {
        lock.lock()
        defer { lock.unlock() }
        return startSequence
    }

    func startedNonce(after sequence: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return startedEvents.first(where: { $0.sequence > sequence })?.nonce
    }

    var currentTitle: String {
        lock.lock()
        let value = title
        lock.unlock()
        return value
    }

    /// Human typing is the only source of genuinely unsubmitted prompt input;
    /// everything else that lands after the OSC 133 B marker (RPROMPT,
    /// suggestion ghost text, ZLE decorations) is display-only. The pane marks
    /// this when bytes arrive outside an AI dispatch, and the READY title of
    /// each new prompt clears it.
    var hasUserTypedSincePrompt: Bool {
        lock.lock()
        defer { lock.unlock() }
        return userTypedSincePrompt
    }

    func markUserTyped() {
        lock.lock()
        userTypedSincePrompt = true
        lock.unlock()
    }

    func resetUserTyped() {
        lock.lock()
        userTypedSincePrompt = false
        lock.unlock()
    }

    /// Enter submits the visible line. Invalidate the old READY title until a
    /// fresh prompt arrives; otherwise a nested shell can inherit both the
    /// stale title and the parent shell's semantic prompt markers.
    func markCommandSubmitted(generation: UUID) {
        lock.lock()
        userTypedSincePrompt = false
        let ready = "__SWIFTTERMINAL_READY=\(generation.uuidString.lowercased())"
        if title == ready {
            title = "__SWIFTTERMINAL_BUSY=\(generation.uuidString.lowercased())"
        }
        lock.unlock()
    }

    /// Completion proofs arrive as transient titles between the command's
    /// proof marker and the next prompt hook. Retain a small window so a fast
    /// command cannot overwrite its proof before the driver's next poll.
    func completionProof(matching nonce: String) -> TerminalCompletionProof? {
        lock.lock()
        let proof = completionProofs[nonce]
        lock.unlock()
        return proof
    }

    func hasStarted(nonce: String) -> Bool {
        lock.lock()
        let started = startedEvents.contains(where: { $0.nonce == nonce })
        lock.unlock()
        return started
    }
}

struct LocalTerminalView: NSViewRepresentable {
    let id: UUID
    var sshHost: SSHHost? = nil
    var appearance = TerminalAppearance()
    var workingDirectory: String? = nil
    var preferredWorkingDirectory: String? = nil
    /// Called once per created terminal view so the workspace can read the
    /// current selection from the visible session, together with the file the
    /// shell writes its exit status to.
    var registerView: ((TerminalPaneView, TerminalProofSource) -> Void)? = nil
    /// Invoked when the shell or SSH process exits.
    var onExit: ((Int32?) -> Void)? = nil
    var onSSHState: ((SSHConnectionState) -> Void)? = nil

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = TerminalPaneView(frame: .zero)
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityRole(.textArea)
        terminal.setAccessibilityLabel("\(sshHost?.displayName ?? "本机")终端")
        terminal.installProcessDelegate(onExit: onExit)
        TerminalAppearanceApplier.apply(appearance, to: terminal)
        let exitStatusFile = Self.exitStatusFile(for: id)
        var proofSource = TerminalProofSource.unavailable(generation: terminal.connectionGeneration)
        try? FileManager.default.removeItem(at: exitStatusFile)
        // SwiftTerm routes unmodified clicks into the active command only when
        // zsh has marked that input using OSC 133. Output and alternate-screen
        // applications retain their normal selection/mouse handling.
        terminal.terminal.semanticPromptClickBehavior = .enabled

        var environment = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "LANG=en_US.UTF-8"
        ]
        if let sshHost {
            if let agentSocket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                environment.append("SSH_AUTH_SOCK=\(agentSocket)")
            }
            if ["bash", "zsh"].contains(sshHost.remoteShell) {
                proofSource = .title(generation: terminal.connectionGeneration)
            }
            terminal.prepareSSH(sshHost, environment: environment, onState: onSSHState)
        } else {
            let shell = Self.resolvedShell(appearance.shellPath)
            let isZsh = (shell as NSString).lastPathComponent == "zsh"
            if isZsh, let integration = ZshShellIntegration.prepare(generation: terminal.connectionGeneration) {
                environment.append(contentsOf: integration.environment)
                environment.append("SWIFTTERMINAL_EXIT_STATUS_FILE=\(exitStatusFile.path)")
                proofSource = .statusFile(exitStatusFile, generation: terminal.connectionGeneration)
            }
            let launchEnvironment = environment
            let startDirectory = Self.startDirectory(appearance: appearance, fallback: workingDirectory, preferred: preferredWorkingDirectory)
            terminal.startWhenSized { [weak terminal] in
                terminal?.startProcess(executable: shell, args: ["-l"],
                                       environment: launchEnvironment, execName: nil,
                                       currentDirectory: startDirectory)
            }
        }
        registerView?(terminal, proofSource)
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        TerminalAppearanceApplier.apply(appearance, to: nsView)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {
        (nsView as? TerminalPaneView)?.stopForRemoval()
    }

    /// Per-session file the shell's prompt hook writes the last exit status to.
    static func exitStatusFile(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftterminal-exit-status-\(id.uuidString)")
    }

    /// Falls back to the login shell when the configured path is missing or not
    /// executable, so a bad setting can never leave the window without a shell.
    static func resolvedShell(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty, FileManager.default.isExecutableFile(atPath: expanded) else { return "/bin/zsh" }
        return expanded
    }

    static func startDirectory(appearance: TerminalAppearance, fallback: String?, preferred: String? = nil) -> String? {
        if let preferred {
            let expanded = (preferred as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue { return expanded }
        }
        let configured = (appearance.startDirectory as NSString).expandingTildeInPath
        guard !appearance.startDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configured, isDirectory: &isDirectory), isDirectory.boolValue else {
            return fallback
        }
        return configured
    }
}

/// Keeps weak references to the terminal views so the workspace can read the
/// text the user selected without keeping closed sessions alive.
@MainActor
final class TerminalViewRegistry {
    private final class Entry {
        weak var view: LocalProcessTerminalView?
        var proofSource: TerminalProofSource

        init(_ view: LocalProcessTerminalView, proofSource: TerminalProofSource) {
            self.view = view
            self.proofSource = proofSource
        }
    }

    private var entries: [UUID: Entry] = [:]

    func register(_ pane: TerminalPaneView, proofSource: TerminalProofSource, for id: UUID) {
        var generationSource = proofSource
        switch generationSource {
        case .statusFile(let url, _):
            generationSource = .statusFile(url, generation: pane.connectionGeneration)
        case .title:
            generationSource = .title(generation: pane.connectionGeneration)
        case .unavailable:
            generationSource = .unavailable(generation: pane.connectionGeneration)
        }
        entries[id] = Entry(pane, proofSource: generationSource)
        entries = entries.filter { $0.value.view != nil }
    }

    /// Live terminal and its exit-status file, or nil when the session has no
    /// running view (closed tab, exited shell, …).
    func liveTerminal(for id: UUID) -> (view: TerminalPaneView, proofSource: TerminalProofSource)? {
        guard let entry = entries[id], let view = entry.view as? TerminalPaneView, view.process?.running == true else { return nil }
        return (view, entry.proofSource)
    }

    /// Sends Ctrl+L so the running shell clears the screen and scrollback.
    func clear(id: UUID) {
        entries[id]?.view?.send(data: [UInt8(0x0C)][...])
    }

    func cancelSSHConnection(id: UUID) {
        (entries[id]?.view as? TerminalPaneView)?.cancelSSHConnection()
    }

    func selection(for id: UUID) -> String? {
        guard let value = entries[id]?.view?.getSelection() else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Adds OSC 133 shell markers without editing the user's existing zsh files.
/// The wrapper files live in Application Support and source the user's normal
/// startup files before enabling click-to-position for this app's shell.
enum ZshShellIntegration {
    private static let userZdotdirVariable = "SWIFTTERMINAL_USER_ZDOTDIR"

    static func prepare(
        generation: UUID,
        directory: URL? = nil,
        userStartupDirectory: String? = nil
    ) -> (directory: URL, environment: [String])? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let originalZdotdir = userStartupDirectory ?? ProcessInfo.processInfo.environment["ZDOTDIR"] ?? home.path
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let integrationDirectory = directory ?? supportRoot
            .appendingPathComponent("SwiftTerminal/ShellIntegration/zsh", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: integrationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let startupFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
            for file in startupFiles {
                let contents: String
                if file == ".zshenv" {
                    contents = zshenv
                } else {
                    let userStartup = "__swiftterminal_source_user_file \(file)"
                    contents = file == ".zshrc" ? "\(userStartup)\n\(interactiveHooks)" : userStartup + "\n"
                }
                let url = integrationDirectory.appendingPathComponent(file)
                try Data(contents.utf8).write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }

            return (
                integrationDirectory,
                [
                    "ZDOTDIR=\(integrationDirectory.path)",
                    "SWIFTTERMINAL_INTEGRATION_ZDOTDIR=\(integrationDirectory.path)",
                    "\(userZdotdirVariable)=\(originalZdotdir)",
                    "SWIFTTERMINAL_CONNECTION_GENERATION=\(generation.uuidString.lowercased())"
                ]
            )
        } catch {
            NSLog("SwiftTerminal: could not prepare zsh shell integration: %@", String(describing: error))
            return nil
        }
    }

    private static let zshenv = #"""
# Generated by SwiftTerminal; user startup files are sourced unchanged.
function __swiftterminal_source_user_file() {
  local file="$1"
  local integration_zdotdir="$ZDOTDIR"
  local user_file="$SWIFTTERMINAL_USER_ZDOTDIR/$file"
  if [[ -r "$user_file" ]]; then
    export ZDOTDIR="$SWIFTTERMINAL_USER_ZDOTDIR"
    source "$user_file"
  fi
  export ZDOTDIR="$integration_zdotdir"
}
__swiftterminal_source_user_file .zshenv
export ZDOTDIR="$SWIFTTERMINAL_INTEGRATION_ZDOTDIR"
"""#

    private static let interactiveHooks = TerminalCommandEnvelope.shellHelpers + "\n" + #"""
# OSC 133 lets SwiftTerm distinguish the editable command from output.
if [[ -o interactive ]]; then
  autoload -Uz add-zsh-hook
  __swiftterminal_prompt_start=$'%{\e]133;A;cl=line\a%}'
  __swiftterminal_prompt_end=$'%{\e]133;B\a%}'

  function __swiftterminal_precmd() {
    local exit_status=$?
    if [[ -n "${__SWIFTTERMINAL_NONCE:-}" ]]; then
      __swiftterminal_end "$exit_status"
    fi
    printf '\e]133;D;%d\a' "$exit_status"
    # ZLE line-init runs before its initial prompt redraw. Put the markers
    # inside PROMPT so every redraw classifies the prompt before editable input.
    PROMPT="${PROMPT#"$__swiftterminal_prompt_start"}"
    PROMPT="${PROMPT%"$__swiftterminal_prompt_end"}"
    PROMPT="${__swiftterminal_prompt_start}${PROMPT}${__swiftterminal_prompt_end}"
    if [[ -n "$SWIFTTERMINAL_CONNECTION_GENERATION" ]]; then
      printf '\e]0;__SWIFTTERMINAL_READY=%s\a' "$SWIFTTERMINAL_CONNECTION_GENERATION"
    fi
  }

  function __swiftterminal_preexec() {
    if [[ -n "$SWIFTTERMINAL_CONNECTION_GENERATION" ]]; then
      __swiftterminal_command_sequence=$((__swiftterminal_command_sequence + 1))
      __swiftterminal_begin "${SWIFTTERMINAL_CONNECTION_GENERATION}-${__swiftterminal_command_sequence}"
      printf '\e]0;__SWIFTTERMINAL_BUSY=%s\a' "$SWIFTTERMINAL_CONNECTION_GENERATION"
    else
      printf '\e]133;C\a'
    fi
  }

  typeset -gi __swiftterminal_command_sequence=0
  add-zsh-hook precmd __swiftterminal_precmd
  add-zsh-hook preexec __swiftterminal_preexec
fi
"""#
}

/// Plans a real `/usr/bin/ssh` launch. bash/zsh targets get temporary remote
/// completion hooks (OSC 133 prompt marks plus READY title) written to a
/// remote mktemp directory, so the AI driver can prove command completion
/// without touching any permanent remote startup file. Other shells keep the
/// unavailable proof source, which refuses AI auto-input but never blocks the
/// person typing.
enum SSHRemoteLaunch {
    struct Plan: Sendable {
        let arguments: [String]
        let environment: [String]
        let proofSource: TerminalProofSource
    }

    static func plan(for host: SSHHost, generation: UUID, extraOptions: [String] = []) -> Plan {
        var arguments = ["-tt", "-p", String(host.port), "-o", "ConnectTimeout=\(SSHConnectionPolicy.connectTimeout(address: host.address))", "-o", "ConnectionAttempts=1"]
        arguments += extraOptions
        var environment: [String] = []
        if host.authentication == .password {
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
            if host.savePassword, !host.password.isEmpty,
               let askpass = try? SSHHostStore.askpassConfiguration(for: host) {
                environment.append(contentsOf: askpass)
            }
        } else if host.authentication == .privateKey {
            arguments += ["-i", (host.privateKeyPath as NSString).expandingTildeInPath]
        }
            arguments.append("\(host.username)@\(host.address)")

        switch host.remoteShell {
        case "bash", "zsh":
            arguments.append(remoteCommand(shell: host.remoteShell, generation: generation))
            return Plan(arguments: arguments, environment: environment,
                proofSource: .title(generation: generation))
        default:
            if !host.remoteShell.isEmpty {
                arguments.append("exec \(host.remoteShell)")
            }
            return Plan(arguments: arguments, environment: environment,
                proofSource: .unavailable(generation: generation))
        }
    }

    /// Internal so PTY tests can run the real remote command locally.
    static func remoteCommand(shell: String, generation: UUID) -> String {
        let generationID = generation.uuidString.lowercased()
        if shell == "zsh" {
            // zsh registers hooks through a temporary ZDOTDIR rc file.
            let hooks = """
            [[ -r "$HOME/.zshrc" ]] && source "$HOME/.zshrc"
            \(TerminalCommandEnvelope.shellHelpers)
            autoload -Uz add-zsh-hook
            __swiftterminal_prompt_start=$'%{\\e]133;A;cl=line\\a%}'
            __swiftterminal_prompt_end=$'%{\\e]133;B\\a%}'
            __swiftterminal_precmd() {
              local st=$?
              printf '\\e]133;D;%d\\a' "$st"
              PROMPT="${PROMPT#"$__swiftterminal_prompt_start"}"
              PROMPT="${PROMPT%"$__swiftterminal_prompt_end"}"
              PROMPT="${__swiftterminal_prompt_start}${PROMPT}${__swiftterminal_prompt_end}"
              printf '\\e]0;__SWIFTTERMINAL_READY=%s\\a' "$SWIFTTERMINAL_CONNECTION_GENERATION"
            }
            __swiftterminal_preexec() { printf '\\e]133;C\\a'; printf '\\e]0;__SWIFTTERMINAL_BUSY=%s\\a' "$SWIFTTERMINAL_CONNECTION_GENERATION"; }
            [[ -o interactive ]] && add-zsh-hook precmd __swiftterminal_precmd && add-zsh-hook preexec __swiftterminal_preexec
            """
            let encoded = Data(hooks.utf8).base64EncodedString()
            return "export SWIFTTERMINAL_CONNECTION_GENERATION='\(generationID)'; __d=$(mktemp -d \"${TMPDIR:-/tmp}/swiftterminal-ssh-XXXXXX\") || exit 127; printf %s \(encoded) | (base64 -d 2>/dev/null || base64 -D) > \"$__d/.zshrc\"; ZDOTDIR=\"$__d\" /bin/zsh -i; __st=$?; rm -rf \"$__d\"; exit $__st"
        }
        // bash needs no remote files at all: PROMPT_COMMAND is set inline,
        // removing every remote dependency (mktemp, base64, writable $HOME).
        // Interactive bash still sources the user's own ~/.bashrc, and the
        // outer command is plain POSIX sh for Synology/busybox login shells.
        // Readline redraws PS1 when a restored tab gets its visible dimensions.
        // Marking only PROMPT_COMMAND loses the active origin during that redraw.
        let promptCommand = "__st=$?\nif ! declare -F __swiftterminal_begin >/dev/null; then\n" + TerminalCommandEnvelope.shellHelpers + "\nfi\n" + #"""
        printf '\033]133;D;%d\a' "$__st"
        __swiftterminal_prompt_start='\[\e]133;A;cl=line\a\]'
        __swiftterminal_prompt_end='\[\e]133;B\a\]'
        PS1="${PS1#"$__swiftterminal_prompt_start"}"
        PS1="${PS1%"$__swiftterminal_prompt_end"}"
        PS1="${__swiftterminal_prompt_start}${PS1}${__swiftterminal_prompt_end}"
        printf '\033]0;__SWIFTTERMINAL_READY=%s\a' "$SWIFTTERMINAL_CONNECTION_GENERATION"
        """#
        let quotedPromptCommand = "'" + promptCommand.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "export SWIFTTERMINAL_CONNECTION_GENERATION='\(generationID)' PROMPT_COMMAND=\(quotedPromptCommand); exec /bin/bash -i"
    }
}
