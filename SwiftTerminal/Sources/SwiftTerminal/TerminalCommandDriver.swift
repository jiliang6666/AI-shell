import AppKit
import Foundation
import SwiftTerm

/// What the shell printed after a command was typed into a live terminal.
struct TerminalRunOutcome {
    var output = ""
    var capturedBytes: Int64 = 0
    var omittedBytes: Int64 = 0
    var captureScope: AIToolCaptureScope = .renderedTerminalBuffer
    var exitStatus: Int32?
    var timedOut = false
    /// True when the shell came back to a prompt, so the session is reusable.
    var returnedToPrompt = false
    /// True when there was no running shell behind the view.
    var unavailable = false
    /// Why the run was refused, shown to the user when a confirmed command
    /// cannot be typed into the terminal.
    var unavailableReason: String? = nil
    /// Set when the run was cut short for a known reason (e.g. the command
    /// sat waiting at a sudo password prompt) so the transcript can say why
    /// instead of a bare "timed out".
    var interruptedReason: String? = nil
}

struct TerminalCompletionProof: Equatable {
    var nonce: String
    var exitStatus: Int32
}

enum TerminalProofSource: Sendable {
    case statusFile(URL, generation: UUID)
    case title(generation: UUID)
    case unavailable(generation: UUID)
}

extension TerminalProofSource {
    var generation: UUID {
        switch self {
        case .statusFile(_, let generation), .title(let generation), .unavailable(let generation): generation
        }
    }

    var supportsCompletionProof: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// Runs a command by typing it into the session's real terminal, then reads the
/// text the shell printed.
///
/// This exists so the assistant can work with the user's actual shell state —
/// current directory, environment, activated toolchains, running jobs — and so
/// the user watches every command happen, instead of a detached helper process
/// quietly running it somewhere else.
/// Bounds for how long the assistant waits, before typing a command into a
/// terminal, for that terminal to come back to a prompt with no pending input.
enum AIReadinessTimeout {
    static let defaultSeconds = 20
    static let range: ClosedRange<Int> = 5...600

    static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// The user's setting as the driver uses it. Read per run so a change in
    /// settings applies to the next command without restarting the app.
    static var configured: TimeInterval {
        TimeInterval(clamp(AppPreferences.load().aiReadinessTimeoutSeconds))
    }
}

@MainActor
final class TerminalCommandDriver {
    static let shared = TerminalCommandDriver()

    nonisolated static let submitByte: UInt8 = 0x0D
    nonisolated static let interruptByte: UInt8 = 0x03
    // Installs and builds can legitimately take a long time. The user can
    // cancel owned work; callers/tests may still supply an explicit deadline.
    nonisolated static let defaultTimeout: TimeInterval = .infinity
    nonisolated static let outputLimit = 24_000

    private let pollInterval: Duration = .milliseconds(60)
    private var activeRuns = Set<UUID>()
    func run(
        _ command: String,
        in view: TerminalPaneView,
        proofSource: TerminalProofSource,
        timeout: TimeInterval = defaultTimeout,
        requiresSudoPassword: Bool = false,
        allowsInteractiveInput: Bool = false,
        sudoPasswordProvider: (() -> String?)? = nil
    ) async -> TerminalRunOutcome {
        guard let terminal = view.terminal, view.process?.running == true else {
            return TerminalRunOutcome(unavailable: true, unavailableReason: "绑定终端的进程未运行或视图不可用")
        }
        guard proofSource.supportsCompletionProof else {
            return TerminalRunOutcome(unavailable: true,
                unavailableReason: "当前终端没有完成证明集成（仅 bash/zsh 支持 AI 自动执行）")
        }
        guard proofSource.generation == view.connectionGeneration else {
            return TerminalRunOutcome(unavailable: true, unavailableReason: "终端会话已重建，代次不匹配；请重试一次")
        }
        // MainActor tasks can interleave while polling. Serialize dispatch to
        // this shell until both its command proof and next prompt arrive.
        let generation = proofSource.generation
        while activeRuns.contains(generation) {
            guard !Task.isCancelled, view.process?.running == true,
                  view.connectionGeneration == generation else {
                return TerminalRunOutcome(unavailable: true, unavailableReason: "等待中的终端命令已取消或会话已结束")
            }
            try? await Task.sleep(for: pollInterval)
        }
        activeRuns.insert(generation)
        defer { activeRuns.remove(generation) }

        let readinessTimeout = AIReadinessTimeout.configured
        let readinessStartedAt = ProcessInfo.processInfo.systemUptime
        // A nested shell (for example sudo -i, su, or manually started SSH)
        // has no pane-specific OSC 133 hooks. Fall back to the conservative
        // unmarked-shell heuristic and a self-proving dispatch payload.
        var unmarkedShell = false
        while true {
            let markedProblem = TerminalRunReading.readinessProblem(
                terminal: terminal,
                title: view.proofBox.currentTitle,
                generation: proofSource.generation,
                userTypedSincePrompt: view.proofBox.hasUserTypedSincePrompt
            )
            if markedProblem == nil {
                break
            }
            let unmarkedProblem = TerminalRunReading.unmarkedShellReadinessProblem(
                terminal: terminal,
                title: view.proofBox.currentTitle,
                userTypedSincePrompt: view.proofBox.hasUserTypedSincePrompt
            )
            if unmarkedProblem == nil {
                unmarkedShell = true
                break
            }
            if unmarkedProblem == TerminalRunReading.ambiguousContinuationPromptProblem {
                return TerminalRunOutcome(unavailable: true, unavailableReason: unmarkedProblem)
            }
            guard view.process?.running == true,
                  view.connectionGeneration == generation,
                  !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime - readinessStartedAt < readinessTimeout else {
                return TerminalRunOutcome(unavailable: true,
                    unavailableReason: "等待 \(Int(readinessTimeout)) 秒未就绪（\(unmarkedProblem ?? markedProblem ?? "原因未知")）")
            }
            try? await Task.sleep(for: pollInterval)
        }
        guard !Task.isCancelled, view.connectionGeneration == generation else {
            return TerminalRunOutcome(unavailable: true, unavailableReason: "命令已取消或终端会话已变更，未派发")
        }

        let lastContentRowBefore = lastContentRow(in: terminal)
        let rowsTrimmedAtStart = terminal.buffer.totalLinesTrimmed
        let wrapperNonce = UUID().uuidString.lowercased()
        let usesLocalShellHooks: Bool = {
            guard !unmarkedShell, !command.isEmpty else { return false }
            if case .statusFile = proofSource { return true }
            return false
        }()
        let startSequence = view.proofBox.latestStartSequence
        var completionNonce: String? = usesLocalShellHooks ? nil : wrapperNonce
        if case .statusFile(let statusFile, _) = proofSource {
            try? FileManager.default.removeItem(at: statusFile)
        }
        defer {
            if let completionNonce, case .statusFile(let statusFile, _) = proofSource {
                try? FileManager.default.removeItem(at: statusFile.appendingPathExtension("\(completionNonce).tmp"))
            }
        }
        var payload: [UInt8]
        if usesLocalShellHooks {
            payload = TerminalCommandEnvelope.inputPayload(command)
        } else {
            let wrapped = unmarkedShell
                ? TerminalCommandEnvelope.wrapSelfProving(command, nonce: wrapperNonce)
                : TerminalCommandEnvelope.wrap(command, nonce: wrapperNonce)
            payload = Array(wrapped.utf8)
        }
        payload.append(Self.submitByte)
        view.sendAIDispatch(payload[...])

        let startedAt = ProcessInfo.processInfo.systemUptime
        let idleLimit = max(8, timeout / 3)
        var lastActivityAt = startedAt
        var lastOutputSignature = Self.outputSignature(terminal)
        var proof: TerminalCompletionProof?
        var returnedToPrompt = false
        var started = false
        var sudoPasswordAttempts = 0
        var lastSentSudoPassword: String?
        var suppressPasswordCheckUntil: TimeInterval = 0
        var interruptedReason: String?
        while !returnedToPrompt {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled, view.process?.running == true,
                  view.connectionGeneration == generation else { break }
            // A dispatched command that sits at `Password:` would otherwise
            // burn the whole timeout. If this task holds a sudo password and
            // the command is sudo-based, feed it once; otherwise interrupt
            // immediately with an actionable reason. User-triggered quick
            // commands leave the terminal available for manual password input.
            let now = ProcessInfo.processInfo.systemUptime
            if !allowsInteractiveInput, now >= suppressPasswordCheckUntil,
               Self.looksLikePasswordPrompt(terminal: terminal) {
                // Try up to two stored passwords (the task's sudo password,
                // then the SSH connection password — same login on most NAS
                // setups). A prompt that reappears after a send means the
                // password was rejected: stop after two tries and let the
                // user supply the right one.
                let candidate = requiresSudoPassword ? sudoPasswordProvider?() : nil
                if sudoPasswordAttempts < 2, let candidate, !candidate.isEmpty,
                   candidate != lastSentSudoPassword {
                    view.sendAIDispatch(Array((candidate + "\r").utf8)[...])
                    sudoPasswordAttempts += 1
                    lastSentSudoPassword = candidate
                    suppressPasswordCheckUntil = now + 0.8
                } else if sudoPasswordAttempts > 0 {
                    interruptedReason = "sudo 密码被拒绝（已自动尝试 \(sudoPasswordAttempts) 个密码），已中断；请在命令确认时提供正确的 sudo 密码，或先在终端执行 sudo -v 后重试"
                    break
                } else {
                    interruptedReason = "命令停在 sudo 密码提示上，已中断；请在命令确认时提供 sudo 密码，或先执行 sudo -v 后重试"
                    break
                }
            }
            // Only runs with an explicit deadline use this idle guard. The AI
            // conversation path waits without a deadline so quiet scans and
            // model-generated commands are left running until completion or stop.
            let signature = Self.outputSignature(terminal)
            if signature != lastOutputSignature {
                lastOutputSignature = signature
                lastActivityAt = ProcessInfo.processInfo.systemUptime
            } else if ProcessInfo.processInfo.systemUptime - lastActivityAt >= idleLimit {
                interruptedReason = "命令 \(Int(idleLimit)) 秒没有任何输出，疑似挂起，已中断。"
                break
            }
            let title = view.proofBox.currentTitle
            if completionNonce == nil {
                completionNonce = view.proofBox.startedNonce(after: startSequence)
            }
            if let nonce = completionNonce {
                started = started || view.proofBox.hasStarted(nonce: nonce)
                    || TerminalRunReading.hasStarted(inTitle: title, nonce: nonce)
                // Keep the matching proof even after precmd replaces the title
                // with READY. The local file is a fallback, never a prompt signal.
                proof = proof ?? view.proofBox.completionProof(matching: nonce)
                if case .statusFile(let statusFile, _) = proofSource {
                    let statusText = try? String(contentsOf: statusFile, encoding: .utf8)
                    started = started || TerminalRunReading.hasStarted(inStatusFile: statusText, nonce: nonce)
                    if let fileProof = TerminalRunReading.completion(fromStatusFile: statusText),
                       fileProof.nonce == nonce {
                        proof = proof ?? fileProof
                    }
                }
                if let currentProof = TerminalRunReading.completion(fromTitle: title), currentProof.nonce == nonce {
                    proof = proof ?? currentProof
                }
            }
            returnedToPrompt = proof != nil && (unmarkedShell
                ? TerminalRunReading.unmarkedShellReadinessProblem(
                    terminal: terminal, title: title,
                    userTypedSincePrompt: view.proofBox.hasUserTypedSincePrompt) == nil
                : TerminalRunReading.isReady(
                    terminal: terminal, title: title, generation: generation,
                    userTypedSincePrompt: view.proofBox.hasUserTypedSincePrompt))
            if ProcessInfo.processInfo.systemUptime - startedAt >= timeout {
                interruptedReason = Self.timeoutDiagnostic(
                    terminal: terminal, title: view.proofBox.currentTitle,
                    nonce: completionNonce ?? wrapperNonce, proofArrived: proof != nil,
                    unmarkedShell: unmarkedShell)
                break
            }
        }

        var timedOut = !returnedToPrompt
        if timedOut, interruptedReason == nil,
           started && proof == nil && view.connectionGeneration == generation {
            interruptedReason = "命令在超时内未返回完成证明"
        }
        if timedOut, view.connectionGeneration == generation {
            // Leave the session usable instead of wedged on a hung command.
            view.sendAIDispatch([Self.interruptByte][...])
            var settleDeadline = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < settleDeadline {
                try? await Task.sleep(for: pollInterval)
                let title = view.proofBox.currentTitle
                let settled = unmarkedShell
                    ? TerminalRunReading.unmarkedShellReadinessProblem(
                        terminal: terminal, title: title,
                        userTypedSincePrompt: view.proofBox.hasUserTypedSincePrompt) == nil
                    : TerminalRunReading.isReady(
                        terminal: terminal, title: title, generation: generation,
                        userTypedSincePrompt: view.proofBox.hasUserTypedSincePrompt)
                if settled { returnedToPrompt = true; break }
            }
            if !returnedToPrompt {
                // The program may ignore SIGINT; one more attempt, then report
                // the terminal state honestly.
                view.sendAIDispatch([Self.interruptByte][...])
                try? await Task.sleep(for: .milliseconds(600))
                if let terminal2 = view.terminal {
                    returnedToPrompt = unmarkedShell
                        ? TerminalRunReading.unmarkedShellReadinessProblem(
                            terminal: terminal2, title: view.proofBox.currentTitle,
                            userTypedSincePrompt: view.proofBox.hasUserTypedSincePrompt) == nil
                        : TerminalRunReading.isReady(
                            terminal: terminal2, title: view.proofBox.currentTitle,
                            generation: generation,
                            userTypedSincePrompt: view.proofBox.hasUserTypedSincePrompt)
                }
            }
            settleDeadline = 0
        }

        let outcome = TerminalRunReading.extract(
            terminal: terminal,
            afterRow: lastContentRowBefore,
            promptBoundary: nil,
            timedOut: timedOut,
            rowsTrimmedAtStart: rowsTrimmedAtStart
        )

        var result = outcome
        result.exitStatus = proof?.exitStatus
        result.timedOut = timedOut
        result.returnedToPrompt = returnedToPrompt
        result.interruptedReason = interruptedReason
        return result
    }

    // MARK: - Terminal inspection

    /// When a dispatched command outlives its timeout, capture the terminal's
    /// actual state into the reason so the transcript carries evidence instead
    /// of a bare "timed out".
    private static func timeoutDiagnostic(
        terminal: Terminal, title: String, nonce: String, proofArrived: Bool,
        unmarkedShell: Bool
    ) -> String {
        var parts: [String] = []
        parts.append(proofArrived ? "完成证明已到达但提示符未恢复" : "未收到完成证明")
        parts.append("标题=\(title.isEmpty ? "空" : title)")
        let rows = terminal.getDims().rows
        let count = TerminalRunReading.lineCount(terminal)
        var shown = 0
        var row = count - 1
        while row >= 0, shown < 3 {
            if let text = TerminalRunReading.lineText(terminal, row: row),
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let clipped = text.trimmingCharacters(in: .whitespaces)
                parts.append("行\(row)=\(clipped.prefix(60))")
                shown += 1
            }
            row -= 1
        }
        let cursor = terminal.getCursorLocation()
        parts.append("光标y=\(cursor.y) x=\(cursor.x)")
        if unmarkedShell { parts.append("降级模式") }
        return "超时（" + parts.joined(separator: "；") + "）"
    }

    /// Cheap fingerprint of what the terminal currently shows: anything that
    /// changes while a command runs (new rows, rewritten progress lines,
    /// cursor moves) counts as output activity.
    private static func outputSignature(_ terminal: Terminal) -> String {
        let count = TerminalRunReading.lineCount(terminal)
        let trimmed = terminal.buffer.totalLinesTrimmed
        let cursor = terminal.getCursorLocation()
        let lastRow = TerminalRunReading.lineText(terminal, row: max(0, count - 1)) ?? ""
        return "\(trimmed)|\(count)|\(cursor.x)|\(cursor.y)|\(lastRow.suffix(80))"
    }

    /// True when the cursor row looks like an interactive password prompt
    /// (`Password:`, `[sudo] password`, `密码：`). Only the cursor row counts:
    /// output rows that merely mention "password" sit above the cursor.
    private static func looksLikePasswordPrompt(terminal: Terminal) -> Bool {
        let rows = terminal.getDims().rows
        let count = TerminalRunReading.lineCount(terminal)
        let cursor = terminal.getCursorLocation()
        let cursorRow = max(0, count - rows) + cursor.y
        guard let text = TerminalRunReading.lineText(terminal, row: cursorRow) else { return false }
        let lowered = text.lowercased()
        return lowered.contains("password") || text.contains("密码")
    }

    private func lastContentRow(in terminal: Terminal) -> Int {
        let count = TerminalRunReading.lineCount(terminal)
        guard count > 0 else { return -1 }
        let lowerBound = max(0, count - 400)
        var last = lowerBound - 1
        for row in lowerBound..<count where !(TerminalRunReading.lineText(terminal, row: row) ?? "").isEmpty {
            last = row
        }
        return last
    }


}

/// Submit one complete shell statement. Raw multiline input runs each line
/// separately, allowing a prompt hook to "complete" the nonce assignment
/// before the actual command. eval keeps cd/export in the user's live shell;
/// quoting keeps comments, apostrophes and here-documents inside that body.
enum TerminalCommandEnvelope {
    // Keep eval at the shell's top level: cd, export and shell options must have
    // exactly the same lifetime as the user's own commands. The helpers only
    // handle protocol markers and the optional local proof file.
    static let shellHelpers = #"""
__swiftterminal_begin() {
  __SWIFTTERMINAL_NONCE="$1"
  builtin printf '\033]133;C\007\033]0;__SWIFTTERMINAL_STARTED=%s\007' "$__SWIFTTERMINAL_NONCE"
}
__swiftterminal_end() {
  local __swiftterminal_exit_status="$1"
  builtin printf '\033]0;__SWIFTTERMINAL_PROOF=%s;%d\007\033]133;P;k=c\007' "$__SWIFTTERMINAL_NONCE" "$__swiftterminal_exit_status"
  if [ -n "${SWIFTTERMINAL_EXIT_STATUS_FILE:-}" ]; then
    local __swiftterminal_proof_tmp="${SWIFTTERMINAL_EXIT_STATUS_FILE}.${__SWIFTTERMINAL_NONCE}.tmp"
    builtin printf '%s\n%d\n' "$__SWIFTTERMINAL_NONCE" "$__swiftterminal_exit_status" > "$__swiftterminal_proof_tmp" && /bin/mv -f "$__swiftterminal_proof_tmp" "$SWIFTTERMINAL_EXIT_STATUS_FILE"
  fi
  unset __SWIFTTERMINAL_NONCE
  return "$__swiftterminal_exit_status"
}
"""#

    static func wrap(_ command: String, nonce: String) -> String {
        "__swiftterminal_begin \(quote(nonce)); builtin eval -- \(quote(command)); __swiftterminal_end $?"
    }

    /// Feed the actual command to an integrated local zsh. Bracketed paste
    /// keeps multiline commands and here-documents in one editable buffer, so
    /// the terminal echoes only the command the user asked the shell to run.
    static func inputPayload(_ command: String) -> [UInt8] {
        var payload: [UInt8] = []
        if command.contains("\n") || command.contains("\r") {
            payload.append(contentsOf: "\u{1B}[200~".utf8)
            payload.append(contentsOf: command.utf8)
            payload.append(contentsOf: "\u{1B}[201~".utf8)
        } else {
            payload.append(contentsOf: command.utf8)
        }
        return payload
    }

    /// For shells without our integration (a nested shell): carry the
    /// whole proof protocol inside the dispatched line itself. POSIX printf
    /// and eval also work in sh/ash without pre-installed hooks.
    static func wrapSelfProving(_ command: String, nonce: String) -> String {
        // Keep OSC bytes textual in the submitted line so readline does not
        // interpret them as editing controls. POSIX printf expands the octal
        // escapes only after the shell executes the wrapper.
        return "printf '\\033]0;__SWIFTTERMINAL_STARTED=%s\\007' \(quote(nonce)); "
            + "eval \(quote(command)); __swiftterminal_st=$?; "
            + "printf '\\033]0;__SWIFTTERMINAL_PROOF=%s;%s\\007' \(quote(nonce)) \"$__swiftterminal_st\""
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Pure reading helpers, split out so the parsing rules can be unit tested.
enum TerminalRunReading {
    static func isReady(
        terminal: Terminal, title: String?, generation: UUID,
        userTypedSincePrompt: Bool
    ) -> Bool {
        readinessProblem(terminal: terminal, title: title, generation: generation,
            userTypedSincePrompt: userTypedSincePrompt) == nil
    }

    /// Explains which readiness condition failed. The prompt path has several
    /// independent requirements, and a bare "not ready" leaves both the user
    /// and the transcript guessing which one broke.
    static func readinessProblem(
        terminal: Terminal, title: String?, generation: UUID,
        userTypedSincePrompt: Bool
    ) -> String? {
        let expected = "__SWIFTTERMINAL_READY=\(generation.uuidString.lowercased())"
        guard title == expected else {
            return "终端标题未报告就绪（当前标题：\(title?.isEmpty == false ? title! : "空")）"
        }
        guard let origin = terminal.activeSemanticPromptOrigin else {
            return "终端没有提示符语义标记；完成证明钩子未安装或 shell 配置覆盖了它"
        }
        let count = lineCount(terminal)
        // SwiftTerm's cursor is relative to the live screen, while yDisp
        // (getTopVisibleRow) follows the user's scrollback viewport. The live
        // screen occupies the final `rows` buffer lines regardless of scrolling.
        let cursor = terminal.getCursorLocation()
        let cursorRow = max(0, count - terminal.getDims().rows) + cursor.y
        guard cursorRow >= origin.row else { return "光标停在当前提示符之前" }
        guard terminal.semanticRowKind(at: cursorRow) != nil
            || cursorIsWithinActivePrompt(terminal: terminal, origin: origin,
                cursorRow: cursorRow, cols: terminal.getDims().cols) else {
            return "光标所在行缺少语义标记"
        }

        guard count > origin.row else { return "缓冲区行数与提示符位置不一致" }
        guard count - origin.row <= 2_000 else { return "提示符之后积累了超过 2000 行输出" }
        // The origin..cursor region must be free of output cells even when no
        // user typing is pending: a stale READY title above a `sudo -i` child
        // shell looks identical to a live prompt until this check runs. Output
        // cells here mean the marked prompt is dead and the driver must fall
        // back to the unmarked-shell mode.
        let livePrompt = terminal.semanticRowKind(at: cursorRow) != nil
            || cursorIsWithinActivePrompt(terminal: terminal, origin: origin,
                cursorRow: cursorRow, cols: terminal.getDims().cols)
        guard userTypedSincePrompt || livePrompt else {
            return "提示符标记已失效（终端可能已进入未集成的子 shell）"
        }
        // RPROMPT (zsh right prompt) and zsh-autosuggestions ghost text are
        // emitted AFTER the OSC 133 B marker, so SwiftTerm tags their cells as
        // input even though nobody typed anything. Tell them apart from a real
        // half-edited command by position: the terminal cursor always sits at
        // the end of the genuine input. Decorations are at/after the cursor;
        // typed text is before it.
        let cols = terminal.getDims().cols
        var promptRows = Set<Int>()
        for row in origin.row..<count {
            guard let line = terminal.bufferLine(atRow: row) else { continue }
            for col in 0..<cols {
                let cell = line[col]
                let character = cell.getCharacter()
                guard character != "\0", cell.width != 0, character != " ",
                      case .some(.prompt) = terminal.semanticContent(at: Position(col: col, row: row)) else { continue }
                promptRows.insert(row)
                break
            }
        }
        guard userTypedSincePrompt else {
            // Nobody typed since this prompt appeared: every input-tagged cell
            // is shell decoration (RPROMPT, suggestion ghost text) or async
            // output, never a pending command. Real typing is gated above.
            return nil
        }
        for row in origin.row..<count {
            guard let line = terminal.bufferLine(atRow: row) else { continue }
            for col in 0..<cols {
                let cell = line[col]
                let character = cell.getCharacter()
                guard character != "\0", cell.width != 0, character != " ",
                      terminal.semanticContent(at: Position(col: col, row: row)) == .input else { continue }
                let beforeCursor = row < cursorRow || (row == cursorRow && col < cursor.x)
                // Input cells on prompt rows are decorations except real text
                // typed before the cursor on the active input line. Rows with
                // no prompt content are typed continuation lines: anything
                // before the cursor is an unsubmitted edit.
                if beforeCursor,
                   !promptRows.contains(row) || row == cursorRow {
                    return "提示符之后仍有未提交的输入（第 \(row - origin.row + 1) 行第 \(col + 1) 列，光标 x=\(cursor.x)）"
                }
            }
        }
        return nil
    }

    /// SwiftTerm stamps hard line-continuation rows only when the shell
    /// advanced with LF/IND. Prompt frameworks that break their prompt lines
    /// with cursor-positioning sequences (CSI CUD/CNL/CUP — powerlevel10k
    /// style frames, right-aligned two-line prompts) leave those rows
    /// unstamped, so a strict `semanticRowKind` check rejects a healthy
    /// prompt. Accept the cursor when every row from the prompt origin to
    /// the cursor either classifies as prompt content or contains only
    /// prompt/input cells; any output cell disqualifies the row so real
    /// command output can never pass as a prompt.
    static func cursorIsWithinActivePrompt(
        terminal: Terminal, origin: Position, cursorRow: Int, cols: Int
    ) -> Bool {
        guard cursorRow >= origin.row else { return false }
        for row in origin.row...cursorRow {
            if terminal.semanticRowKind(at: row) != nil { continue }
            guard let line = terminal.bufferLine(atRow: row) else { continue }
            for col in 0..<cols {
                let cell = line[col]
                let character = cell.getCharacter()
                let visible = character != "\0" && cell.width != 0 && character != " "
                let content = terminal.semanticContent(at: Position(col: col, row: row))
                if case .output? = content { return false }
                guard visible else { continue }
                switch content {
                case .some(.prompt), .some(.input): continue
                default: return false
                }
            }
        }
        return true
    }

    /// Readiness for shells without OSC 133 hooks (`sudo -i` child shells).
    /// Deliberately conservative: any full-screen program, a cursor that is
    /// not at the end of the last content row, or a last row that does not
    /// look like a shell prompt refuses the dispatch. This mode never scans
    /// semantic cells — there are none to trust — so it is only reached when
    /// the marked readiness check has already failed.
    static func unmarkedShellReadinessProblem(
        terminal: Terminal, title: String?, userTypedSincePrompt: Bool
    ) -> String? {
        if userTypedSincePrompt {
            return "无集成 shell 中存在未提交的用户输入，无法安全定位"
        }
        if terminal.isCurrentBufferAlternate {
            return "全屏程序正在占用终端"
        }
        let cols = terminal.getDims().cols
        let rows = terminal.getDims().rows
        let count = lineCount(terminal)
        let cursor = terminal.getCursorLocation()
        let cursorRow = max(0, count - rows) + cursor.y
        var lastContentRow: Int?
        var row = count - 1
        while row >= max(0, count - rows * 4) {
            if let text = lineText(terminal, row: row),
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lastContentRow = row
                break
            }
            row -= 1
        }
        guard let last = lastContentRow, cursorRow == last else {
            return "光标不在最后一行（可能正在运行交互程序）"
        }
        // A continuation prompt such as Bash's PS2 can be drawn while the
        // shell is still accepting the previous command. When the foreground
        // shell is local, OSC 133 still identifies those editable cells even
        // though its READY title has been invalidated; never dispatch there.
        if let line = terminal.bufferLine(atRow: last) {
            for col in 0..<min(cols, max(0, cursor.x)) {
                let cell = line[col]
                let character = cell.getCharacter()
                guard character != "\0", character != " ", cell.width != 0 else { continue }
                if terminal.semanticContent(at: Position(col: col, row: last)) == .input {
                    return "无集成 shell 中仍有可编辑输入（可能是续行提示符）"
                }
            }
        }
        guard let line = terminal.bufferLine(atRow: last) else {
            return "无法读取终端最后一行"
        }
        let promptText = line.translateToString(trimRight: true)
        if promptText.trimmingCharacters(in: .whitespaces).hasSuffix(">") {
            return ambiguousContinuationPromptProblem
        }
        var lastNonSpaceCol = -1
        for col in (0..<cols).reversed() {
            let character = line[col].getCharacter()
            if character != "\0", character != " " {
                lastNonSpaceCol = col
                break
            }
        }
        guard lastNonSpaceCol >= 0,
              looksLikeUnmarkedShellPrompt(promptText) else {
            return "最后一行不是 shell 提示符"
        }
        guard cursor.x >= lastNonSpaceCol else {
            return "光标停在提示符之前"
        }
        return nil
    }

    static let ambiguousContinuationPromptProblem =
        "无集成 shell 的“>”提示符无法与 Bash 续行提示符区分，已阻止 AI 派发"

    /// The final punctuation alone is too weak: progress output like `50%`
    /// must not authorize typing into a foreground process. Accept common
    /// shell-shaped suffixes (`user@host:~/path$`, `root#`, `host%`) and bare
    /// prompts. Unmarked `>` prompts are rejected by the caller because Bash
    /// also uses `>` as its default PS2 continuation prompt.
    static func looksLikeUnmarkedShellPrompt(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let marker = text.last, "#$%".contains(marker) else { return false }
        let prefix = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return true }
        let token = prefix.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        guard !token.isEmpty else { return false }
        switch marker {
        case "%":
            // zsh commonly ends in `host%`; reject numeric progress such as
            // `50%` even when earlier words happen to contain letters.
            return token.contains(where: \.isLetter)
        case "#", "$":
            return token.contains(where: \.isLetter) || token.contains("~") || token.contains("/") || token.contains("@")
        default:
            return false
        }
    }

    static func hasStarted(inStatusFile contents: String?, nonce: String) -> Bool {
        guard let contents else { return false }
        return contents.split(whereSeparator: { $0.isNewline }).first.map(String.init) == nonce
    }

    static func hasStarted(inTitle title: String, nonce: String) -> Bool {
        title == "__SWIFTTERMINAL_STARTED=\(nonce)" ||
            completion(fromTitle: title)?.nonce == nonce
    }

    /// A shell that exits non-zero records the status in a file; anything that
    /// is not a plain integer is treated as unknown.
    static func exitStatus(fromStatusFile contents: String?) -> Int32? {
        guard let contents else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int32(trimmed) else { return nil }
        return value
    }

    static func completion(fromStatusFile contents: String?) -> TerminalCompletionProof? {
        guard let contents else { return nil }
        let lines = contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, let status = Int32(lines[lines.count - 1]) else { return nil }
        return TerminalCompletionProof(nonce: lines[0], exitStatus: status)
    }

    static func completion(fromTitle title: String?) -> TerminalCompletionProof? {
        guard let title, title.hasPrefix("__SWIFTTERMINAL_PROOF=") else { return nil }
        let payload = title.dropFirst("__SWIFTTERMINAL_PROOF=".count)
        let parts = payload.split(separator: ";", maxSplits: 1)
        guard parts.count == 2, let status = Int32(parts[1]) else { return nil }
        return TerminalCompletionProof(nonce: String(parts[0]), exitStatus: status)
    }

    /// Text of a buffer-absolute row, or nil when the row does not exist.
    static func lineText(_ terminal: Terminal, row: Int) -> String? {
        let offset = terminal.buffer.totalLinesTrimmed
        return terminal.getScrollInvariantLine(row: row + offset)?.translateToString(trimRight: true)
    }

    /// Number of buffer rows, derived from the public line accessor because
    /// SwiftTerm keeps its raw line array internal.
    static func lineCount(_ terminal: Terminal) -> Int {
        let offset = terminal.buffer.totalLinesTrimmed
        func exists(_ row: Int) -> Bool {
            terminal.getScrollInvariantLine(row: row + offset) != nil
        }
        guard exists(0) else { return 0 }
        var high = 1
        while exists(high) {
            high *= 2
            if high > 1 << 20 { break }
        }
        var low = high / 2
        while low + 1 < high {
            let mid = (low + high) / 2
            if exists(mid) { low = mid } else { high = mid }
        }
        return low + 1
    }

    /// The semantic role of a row, looked up across the row because an output
    /// row commonly starts with a blank cell that carries no role.
    static func rowRole(_ terminal: Terminal, row: Int) -> SemanticContent? {
        for col in 0..<terminal.getDims().cols {
            guard let content = terminal.semanticContent(at: Position(col: col, row: row)) else { break }
            if content != SemanticContent.none { return content }
        }
        return nil
    }

    /// Read output cells only, preserving soft wraps and the boundary even if
    /// scrollback was trimmed while the command ran. A prompt can share its row
    /// with output, so filtering whole rows is insufficient.
    static func extract(
        terminal: Terminal,
        afterRow: Int,
        promptBoundary: Int?,
        timedOut: Bool,
        rowsTrimmedAtStart: Int = 0
    ) -> TerminalRunOutcome {
        let count = lineCount(terminal)
        let removedRows = max(0, terminal.buffer.totalLinesTrimmed - rowsTrimmedAtStart)
        let start = max(0, afterRow + 1 - removedRows)
        let end = min(count, promptBoundary.map { $0 + 1 } ?? count)
        guard start < end else { return TerminalRunOutcome() }
        var lines: [String] = []
        var hasMarkedOutput = false
        var fallback: [String] = []
        for row in start..<end {
            guard let line = terminal.bufferLine(atRow: row) else { continue }
            var output = ""
            var hasOutput = false
            for col in 0..<terminal.getDims().cols {
                let cell = line[col]
                guard cell.semanticContent == .output else { continue }
                hasOutput = true
                guard cell.width != 0 else { continue }
                let character = cell.getCharacter()
                output += character == "\0" ? " " : String(character)
            }
            if hasOutput {
                hasMarkedOutput = true
                // Wrapped rows join without an artificial newline. Keep spaces
                // at a full-width boundary; only trim final screen padding.
                if terminal.bufferLine(atRow: row + 1)?.isWrapped != true {
                    while let last = output.last, last == " " || last == "\t" { output.removeLast() }
                }
                if line.isWrapped, !lines.isEmpty { lines[lines.count - 1] += output }
                else { lines.append(output) }
            } else if !hasMarkedOutput, rowRole(terminal, row: row) == nil {
                fallback.append(line.translateToString(trimRight: true))
            }
        }
        let text = trimmedBlock(hasMarkedOutput ? lines : fallback)
        let captured = AIToolOutputLimiter.capture(text)
        return TerminalRunOutcome(output: captured.text, capturedBytes: captured.capturedBytes,
            omittedBytes: captured.omittedBytes, captureScope: .renderedTerminalBuffer)
    }

    /// Drops the blank padding the terminal keeps below the last written row
    /// while keeping intentional blank lines inside the output.
    static func trimmedBlock(_ lines: [String]) -> String {
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        return lines[first...last].joined(separator: "\n")
    }

    /// Terminal output can be far larger than a model turn can hold, so it is
    /// clipped with a marker rather than silently truncated.
    static func limitedOutput(_ text: String, limit: Int = TerminalCommandDriver.outputLimit) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        return "\(head)\n…（输出过长，已截断，仅保留前 \(limit) 个字符）"
    }
}
