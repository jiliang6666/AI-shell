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
