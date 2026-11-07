import Foundation
import AppKit
import Testing
@testable import SwiftTerminal

@Test("Ordinary instructions, quoted examples, authentication and conditional suggestions do not become questions", arguments: [
    "任务已完成。\n1. 检查环境\n2. 安装依赖",
    "示例：\n```text\n请选择方式：\n1. A\n2. B\n```",
    "> 请选择方式：\n> 1. A\n> 2. B",
    "如果你以后需要，请选择其他方式。",
    "请确认终端中的 SSH 指纹。",
    "请确认密码。",
    "请选择弹出的对话框中的文件。\n完成后即可使用。"
])
func proseQuestionDoesNotMisclassify(_ text: String) {
    #expect(AITextQuestionParser.parse(text) == nil)
}

@Test("Explicit final choice requests retain their labels and never select automatically", arguments: [
    "请选择安装方式：\n1. 保留配置\n2. 重新配置",
    "- 保留配置\n- 重新配置\n请回复选项编号。"
])
func proseQuestionRetainsChoices(_ text: String) throws {
    let question = try #require(AITextQuestionParser.parse(text))
    #expect(question.options.map(\.label) == ["保留配置", "重新配置"])
    #expect(question.recommendedOptionID == nil)
}

@Test("Document growth follows output, user scrolling pauses it, and reaching the bottom resumes")
func chatScrollDoesNotPullReaderAway() {
    var tracking = AIChatScrollTracking()
    let states = [
        tracking.update(documentHeight: 1000, viewportHeight: 400, offset: 600, userDriven: false),
        tracking.update(documentHeight: 1200, viewportHeight: 400, offset: 600, userDriven: false),
        tracking.update(documentHeight: 1200, viewportHeight: 400, offset: 200, userDriven: true),
        tracking.update(documentHeight: 1500, viewportHeight: 400, offset: 200, userDriven: false),
        tracking.update(documentHeight: 1500, viewportHeight: 400, offset: 1100, userDriven: true)
    ]
    #expect(states == [true, true, false, false, true])
}

@Test("Output excludes command echo and a prompt sharing the same row, and keeps soft wraps intact")
@MainActor
func renderedOutputKeepsOnlyCommandBytes() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 12, rows: 8)
    let output = "12345678901 这是长输出 /a/b/c/d/e/f/g"
    terminal.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}INTERNAL_ECHO\r\n\u{1b}]133;C\u{7}\(output)\u{1b}]133;A\u{7}PROMPT\u{1b}]133;B\u{7}")
    let result = TerminalRunReading.extract(terminal: terminal, afterRow: -1, promptBoundary: nil, timedOut: false)
    #expect(result.output == output)
    #expect(!result.output.contains("INTERNAL_ECHO"))
    #expect(!result.output.contains("PROMPT"))
}

@Test("Scrollback trimming cannot move the output boundary past the final command output")
@MainActor
func renderedOutputSurvivesScrollbackTrimming() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 40, rows: 8)
    terminal.changeScrollback(12)
    terminal.feed(text: String(repeating: "old\r\n", count: 30))
    let boundary = TerminalRunReading.lineCount(terminal) - 1
    let trimmed = terminal.buffer.totalLinesTrimmed
    terminal.feed(text: "\u{1b}]133;C\u{7}" + String(repeating: "new\r\n", count: 50) + "LAST_VISIBLE_MARKER\r\n\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    let result = TerminalRunReading.extract(terminal: terminal, afterRow: boundary, promptBoundary: nil, timedOut: false, rowsTrimmedAtStart: trimmed)
    #expect(terminal.buffer.totalLinesTrimmed > trimmed)
    #expect(result.output.contains("LAST_VISIBLE_MARKER"))
    #expect(!result.output.contains("old"))
}

@Test("Output survives a bash hook that retags command output as editable input")
@MainActor
func renderedOutputSurvivesInputRetaggingAfterCommandEcho() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 72, rows: 12)
    let nonce = UUID().uuidString.lowercased()
    terminal.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    terminal.feed(text: "__swiftterminal_begin '\(nonce)'; builtin eval -- 'printf SHA'; __swiftterminal_end $? '\(nonce)'\r\n")
    // A DEBUG/preexec hook can send B after the wrapper's C marker and before
    // the command body, retagging both stdout and stderr as editable input.
    terminal.feed(text: "\u{1b}]133;C\u{7}\u{1b}]133;B\u{7}STDOUT_ROW\r\nSTDERR_ROW\r\n")
    terminal.feed(text: "\u{1b}]133;A\u{7}PROMPT\u{1b}]133;B\u{7}")

    let result = TerminalRunReading.extract(
        terminal: terminal,
        afterRow: -1,
        promptBoundary: nil,
        timedOut: false,
        echoBoundary: nonce
    )
    #expect(result.output == "STDOUT_ROW\nSTDERR_ROW")
    #expect(!result.output.contains("__swiftterminal_begin"))
    #expect(!result.output.contains(nonce))
    #expect(!result.output.contains("PROMPT"))
    #expect(result.capturedBytes > 0)
}

@Test("STARTED title captures input-tagged output after a single-row wrapper echo")
@MainActor
func outputStartRowCapturesAfterPromptRowEcho() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 160, rows: 12)
    let nonce = UUID().uuidString.lowercased()
    terminal.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
    terminal.feed(text: "__swiftterminal_begin '\(nonce)'; builtin eval -- 'printf SHA'; __swiftterminal_end $? '\(nonce)'\r\n")
    #expect(terminal.getCursorLocation().y == 1)
    pane.prepareAIAutomation()
    pane.markAIAutomationDispatched()
    pane.receivedTitle("__SWIFTTERMINAL_STARTED=\(nonce)")
    let outputStartRow = try #require(pane.aiOutputStartRow(for: nonce))

    terminal.feed(text: "\u{1b}]133;B\u{7}FIRST_OUTPUT\r\n")
    pane.receivedTitle("__SWIFTTERMINAL_STARTED=\(nonce)")
    #expect(pane.aiOutputStartRow(for: nonce) == outputStartRow)
    for index in 0..<128 {
        pane.receivedTitle("__SWIFTTERMINAL_STARTED=FAKE_NONCE_\(index)")
    }
    #expect(pane.aiOutputStartRow(for: nonce) == outputStartRow)

    terminal.feed(text: "STDOUT_ROW\r\nSTDERR_ROW\r\n")
    let result = TerminalRunReading.extract(
        terminal: terminal,
        afterRow: -1,
        promptBoundary: nil,
        timedOut: false,
        echoBoundary: nonce,
        outputStartRow: outputStartRow
    )
    #expect(result.output == "FIRST_OUTPUT\nSTDOUT_ROW\nSTDERR_ROW")
    #expect(!result.output.contains("__swiftterminal_begin"))
}

@Test("Absolute output start excludes retained scrollback trimmed before dispatch")
@MainActor
func outputStartRowExcludesPreDispatchScrollback() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 40, rows: 8)
    terminal.changeScrollback(12)
    terminal.feed(text: String(repeating: "OLD_RETAINED_MARKER\r\n", count: 30))
    #expect(terminal.buffer.totalLinesTrimmed > 0)
    #expect((0..<TerminalRunReading.lineCount(terminal)).contains {
        TerminalRunReading.lineText(terminal, row: $0)?.contains("OLD_RETAINED_MARKER") == true
    })

    let nonce = UUID().uuidString.lowercased()
    terminal.feed(text: "__swiftterminal_begin '\(nonce)'; eval output\r\n")
    pane.prepareAIAutomation()
    pane.markAIAutomationDispatched()
    pane.receivedTitle("__SWIFTTERMINAL_STARTED=\(nonce)")
    let outputStartRow = try #require(pane.aiOutputStartRow(for: nonce))
    #expect(outputStartRow >= terminal.buffer.totalLinesTrimmed)

    terminal.feed(text: "NEW_RESULT\r\n")
    let result = TerminalRunReading.extract(
        terminal: terminal,
        afterRow: -1,
        promptBoundary: nil,
        timedOut: false,
        outputStartRow: outputStartRow
    )
    #expect(result.output == "NEW_RESULT")
    #expect(!result.output.contains("OLD_RETAINED_MARKER"))
}

@Test("Recorded output start survives scrollback trimming")
@MainActor
func outputStartRowSurvivesScrollbackTrimming() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 40, rows: 8)
    terminal.changeScrollback(12)
    terminal.feed(text: String(repeating: "old\r\n", count: 30))

    let nonce = UUID().uuidString.lowercased()
    terminal.feed(text: "__swiftterminal_begin '\(nonce)'; eval output\r\n")
    pane.prepareAIAutomation()
    pane.markAIAutomationDispatched()
    pane.receivedTitle("__SWIFTTERMINAL_STARTED=\(nonce)")
    let outputStartRow = try #require(pane.aiOutputStartRow(for: nonce))

    terminal.feed(text: "\u{1b}]133;B\u{7}" + String(repeating: "kept output\r\n", count: 40) + "LAST_VISIBLE_MARKER\r\n")
    #expect(terminal.buffer.totalLinesTrimmed > outputStartRow)
    let result = TerminalRunReading.extract(
        terminal: terminal,
        afterRow: -1,
        promptBoundary: nil,
        timedOut: false,
        outputStartRow: outputStartRow
    )
    #expect(result.output.contains("LAST_VISIBLE_MARKER"))
    #expect(!result.output.contains("old"))
}

@Test("Marked wrapper echo before the echo boundary is excluded")
@MainActor
func markedWrapperEchoBeforeEchoBoundaryIsExcluded() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 160, rows: 12)
    let nonce = UUID().uuidString.lowercased()
    terminal.feed(text: "\u{1b}]133;C\u{7}__swiftterminal_begin '\(nonce)'; builtin eval -- 'printf SHA'; __swiftterminal_end $? '\(nonce)'\r\n")
    terminal.feed(text: "\u{1b}]133;B\u{7}REAL_OUTPUT_ROW\r\n")

    let result = TerminalRunReading.extract(
        terminal: terminal,
        afterRow: -1,
        promptBoundary: nil,
        timedOut: false,
        echoBoundary: nonce
    )
    #expect(result.output == "REAL_OUTPUT_ROW")
    #expect(!result.output.contains("__swiftterminal_begin"))
    #expect(!result.output.contains(nonce))
}

@Test("Stale automation callbacks cannot interrupt or finish a newer run")
@MainActor
func staleAutomationCallbacksDoNotAffectNewRun() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
    let firstRunID = UUID()
    let secondRunID = UUID()

    pane.prepareAIAutomation(runID: firstRunID)
    pane.markAIAutomationDispatched(runID: firstRunID)
    pane.prepareAIAutomation(runID: secondRunID)
    pane.markAIAutomationDispatched(runID: secondRunID)

    #expect(!pane.interruptAIAutomation(runID: firstRunID))
    #expect(!pane.retryInterruptAIAutomation(runID: firstRunID))
    pane.finishAIAutomation(runID: firstRunID)
    #expect(pane.interruptAIAutomation(runID: secondRunID))
    #expect(!pane.interruptAIAutomation(runID: secondRunID))
    #expect(pane.retryInterruptAIAutomation(runID: secondRunID))
}

@Test("Enter excludes its input row without excluding the first output row")
@MainActor
func enterDoesNotExcludeTheNextOutputRow() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 160, rows: 12)
    let runID = UUID()
    pane.prepareAIAutomation(runID: runID)
    pane.markAIAutomationDispatched(runID: runID)

    let inputRow = terminal.buffer.totalLinesTrimmed
        + max(0, TerminalRunReading.lineCount(terminal) - terminal.getDims().rows)
        + terminal.getCursorLocation().y
    pane.send(source: pane, data: Array("OK\r".utf8)[...])
    let inputExclusions = pane.aiUserInputExclusions()
    #expect(inputExclusions.columnsByAbsoluteRow[inputRow] == Set([0, 1, 2]))
    #expect(inputExclusions.columnsByAbsoluteRow[inputRow + 1] == nil)

    pane.sendAIDispatch(Array("sudo".utf8)[...])
    pane.forwardingTerminalInitiatedSend = true
    pane.send(source: pane, data: Array("terminal response".utf8)[...])
    pane.forwardingTerminalInitiatedSend = false
    #expect(pane.aiUserInputExclusions().columnsByAbsoluteRow == inputExclusions.columnsByAbsoluteRow)

    terminal.feed(text: "\u{1b}]133;B\u{7}OK\r\n\u{1b}]133;C\u{7}RESULT=OK\r\n")
    let result = TerminalRunReading.extract(
        terminal: terminal,
        afterRow: -1,
        promptBoundary: nil,
        timedOut: false,
        inputExclusions: inputExclusions
    )
    #expect(result.output == "RESULT=OK")
}

@Test("Wrapped ASCII paste and wide UTF-8 characters are excluded by cell")
@MainActor
func wrappedAndWideInputCellsAreExcluded() throws {
    func run(cols: Int, prefix: String, input: String) throws -> String {
        let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        let terminal = try #require(pane.terminal)
        terminal.resize(cols: cols, rows: 8)
        terminal.feed(text: "\u{1b}]133;C\u{7}\(prefix)")
        let runID = UUID()
        pane.prepareAIAutomation(runID: runID)
        pane.markAIAutomationDispatched(runID: runID)
        pane.send(source: pane, data: Array(input.utf8)[...])
        let inputExclusions = pane.aiUserInputExclusions()
        terminal.feed(text: input)
        return TerminalRunReading.extract(
            terminal: terminal,
            afterRow: -1,
            promptBoundary: nil,
            timedOut: false,
            inputExclusions: inputExclusions
        ).output
    }

    #expect(try run(cols: 8, prefix: "PREFIX", input: String(repeating: "A", count: 12)) == "PREFIX")
    #expect(try run(cols: 8, prefix: "12345", input: "中文") == "12345")
}

@Test("Marked and fallback output keep a prefix before same-row input")
@MainActor
func inputCellsPreserveSameRowPrefix() throws {
    for marked in [false, true] {
        let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        let terminal = try #require(pane.terminal)
        terminal.resize(cols: 80, rows: 8)
        terminal.feed(text: marked ? "\u{1b}]133;C\u{7}PREFIX" : "PREFIX")
        let runID = UUID()
        pane.prepareAIAutomation(runID: runID)
        pane.markAIAutomationDispatched(runID: runID)
        pane.send(source: pane, data: Array("SECRET".utf8)[...])
        let inputExclusions = pane.aiUserInputExclusions()
        terminal.feed(text: "SECRET\r\n")

        let result = TerminalRunReading.extract(
            terminal: terminal,
            afterRow: -1,
            promptBoundary: nil,
            timedOut: false,
            inputExclusions: inputExclusions
        )
        #expect(result.output == "PREFIX")
    }
}

@Test("Editing keys conservatively exclude their current row")
@MainActor
func editingKeysExcludeTheirTerminalRow() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 40, rows: 8)
    let runID = UUID()
    pane.prepareAIAutomation(runID: runID)
    pane.markAIAutomationDispatched(runID: runID)

    pane.send(source: pane, data: Array("\u{1b}[A".utf8)[...])
    pane.send(source: pane, data: [UInt8(0x15)][...])
    pane.send(source: pane, data: [UInt8(0x17)][...])
    let inputExclusions = pane.aiUserInputExclusions()
    #expect(inputExclusions.columnsByAbsoluteRow.values.first?.count == 40)

    terminal.feed(text: "\u{1b}]133;C\u{7}EDITED_LINE\r\n")
    let result = TerminalRunReading.extract(
        terminal: terminal,
        afterRow: -1,
        promptBoundary: nil,
        timedOut: false,
        inputExclusions: inputExclusions
    )
    #expect(result.output.isEmpty)
}

@Test("Input cell overflow fails closed and reports a safe truncation reason")
@MainActor
func inputCellLedgerOverflowTruncatesAndClears() throws {
    let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
    let terminal = try #require(pane.terminal)
    terminal.resize(cols: 80, rows: 8)
    terminal.changeScrollback(5_000)
    let runID = UUID()
    pane.prepareAIAutomation(runID: runID)
    pane.markAIAutomationDispatched(runID: runID)

    let longPaste = String(repeating: "x", count: 17_000)
    pane.send(source: pane, data: Array(longPaste.utf8)[...])
    let inputExclusions = pane.aiUserInputExclusions()
    #expect(inputExclusions.overflowFromRow != nil)
    #expect(inputExclusions.overflowInterruptionReason == "人工输入记录超限，输出尾部已安全截断")

    terminal.feed(text: "\u{1b}]133;C\u{7}\(longPaste)\r\n")
    let result = TerminalRunReading.extract(
        terminal: terminal,
        afterRow: -1,
        promptBoundary: nil,
        timedOut: false,
        inputExclusions: inputExclusions
    )
    #expect(result.output.isEmpty)

    pane.finishAIAutomation(runID: runID)
    let clearedExclusions = pane.aiUserInputExclusions()
    #expect(clearedExclusions.columnsByAbsoluteRow.isEmpty)
    #expect(clearedExclusions.overflowFromRow == nil)
}

@Test("Structured result status takes precedence over legacy strings and does not enter the model request")
func commandResultMetadataStaysLocal() throws {
    var message = ChatMessage(role: "tool", content: "退出码：0\n采集范围：完整输出\n\n日志", name: "run_command", toolCallID: "call")
    message.commandResult = AICommandResultMetadata(status: .unknown, command: "pwd", purpose: "检查目录", omittedBytes: 5)
    let presentation = AICommandResultPresentation(message: message)
    #expect(presentation.status == .unknown)
    #expect(presentation.command == "pwd")
    #expect(presentation.output == "日志")
    #expect(presentation.isPartial)
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    #expect(object["commandResult"] == nil)
    let restored = try JSONDecoder().decode(AIStoredMessage.self, from: JSONEncoder().encode(AIStoredMessage(message: message))).message
    #expect(restored.commandResult == message.commandResult)
    #expect(AICommandResultPresentation.content("退出码：未知\n采集范围：完整输出\n\n日志") == "命令完成状态未确认。\n\n日志")
}

@Test("Repeated provider call IDs in different requests remain paired with their own commands")
func transcriptCommandsPairByRequest() {
    let turnID = UUID()
    let firstRequest = UUID()
    let secondRequest = UUID()
    func assistant(_ command: String, request: UUID) -> ChatMessage {
        ChatMessage(role: "assistant", toolCalls: [.init(id: "same", function: .init(name: "run_command", arguments: "{\"command\":\"\(command)\",\"purpose\":\"\(command)\"}"))], turnID: turnID, requestID: request)
    }
    let firstResult = ChatMessage(role: "tool", content: "one", toolCallID: "same", turnID: turnID, requestID: firstRequest)
    let secondResult = ChatMessage(role: "tool", content: "two", toolCallID: "same", turnID: turnID, requestID: secondRequest)
    let rows = AIChatTranscriptPresentation.rows([assistant("pwd", request: firstRequest), firstResult, assistant("ls", request: secondRequest), secondResult])
    #expect(rows[1].descriptor?.command == "pwd")
    #expect(rows[3].descriptor?.command == "ls")
}

@Test("A cached transcript updates streamed calls and revised results without retaining stale commands")
func transcriptProjectionRefreshesChangedMessages() {
    var projection = AIChatTranscriptPresentation()
    let turnID = UUID(), requestID = UUID()
    var assistant = ChatMessage(role: "assistant", content: "正在检查", turnID: turnID, requestID: requestID)
    var result = ChatMessage(role: "tool", content: "旧输出", toolCallID: "call", turnID: turnID, requestID: requestID)
    let initial = projection.project([assistant, result])
    #expect(initial.last?.result?.command == nil)
    assistant.toolCalls = [.init(id: "call", function: .init(name: "run_command", arguments: #"{"command":"pwd","purpose":"检查目录"}"#))]
    result.content = "新输出"
    result.commandResult = AICommandResultMetadata(status: .completed)
    let revised = projection.project([assistant, result])
    #expect(revised.last?.result?.command == "pwd")
    #expect(revised.last?.result?.output == "新输出")
    #expect(revised.last?.result?.status == .completed)
    #expect(projection.project([]).isEmpty)
}
