import Foundation
import Testing
@testable import SwiftTerminal

@Test("Command timing formats seconds, minutes, hours, and unavailable values")
func commandTimingFormatting() {
    #expect(CommandTimingFormatter.elapsed(0) == "0.0 秒")
    #expect(CommandTimingFormatter.elapsed(0.44) == "0.4 秒")
    #expect(CommandTimingFormatter.elapsed(12.34) == "12.3 秒")
    #expect(CommandTimingFormatter.elapsed(59.96) == "1 分 00 秒")
    #expect(CommandTimingFormatter.elapsed(65) == "1 分 05 秒")
    #expect(CommandTimingFormatter.elapsed(3_723) == "1 小时 02 分 03 秒")
    #expect(CommandTimingFormatter.elapsed(nil) == nil)
    #expect(CommandTimingFormatter.elapsed(-1) == nil)
    #expect(CommandTimingFormatter.elapsed(.infinity) == nil)
    #expect(CommandTimingFormatter.elapsed(.nan) == nil)
    #expect(CommandTimingFormatter.elapsed(1e30) == nil)
}

@Test("Command result metadata keeps duration and decodes older records")
func commandTimingMetadataCompatibility() throws {
    let legacy = Data(#"{"status":"completed","command":"pwd","purpose":"检查目录","omittedBytes":0}"#.utf8)
    let oldMetadata = try JSONDecoder().decode(AICommandResultMetadata.self, from: legacy)
    #expect(oldMetadata.durationSeconds == nil)

    let metadata = AICommandResultMetadata(
        status: .completed,
        command: "sleep 12",
        purpose: "等待",
        durationSeconds: 12.34
    )
    let restored = try JSONDecoder().decode(
        AICommandResultMetadata.self,
        from: JSONEncoder().encode(metadata)
    )
    #expect(restored.durationSeconds == 12.34)

    let message = ChatMessage(role: "tool", content: "完成", commandResult: metadata)
    let presentation = AICommandResultPresentation(message: message)
    #expect(presentation.durationText == "12.3 秒")
    #expect(presentation.durationLabel == "耗时")

    let split = AICommandResultMetadata(
        status: .completed,
        durationSeconds: 2.5,
        totalDurationSeconds: 12.34
    )
    let splitPresentation = AICommandResultPresentation(
        message: ChatMessage(role: "tool", content: "完成", commandResult: split)
    )
    #expect(splitPresentation.durationText == "12.3 秒")
    #expect(splitPresentation.durationLabel == "总耗时")
    #expect(splitPresentation.runDurationText == "2.5 秒")
    #expect(splitPresentation.showsRunDuration)
}

@Test("Execution history keeps duration and decodes legacy records")
func executionRecordTimingCompatibility() throws {
    let legacy = Data(#"{"targetName":"本机","command":"pwd","output":"/tmp","exitCode":0,"startedAt":0}"#.utf8)
    let oldRecord = try JSONDecoder().decode(ExecutionRecord.self, from: legacy)
    #expect(oldRecord.durationSeconds == nil)

    let record = ExecutionRecord(
        targetName: "本机",
        hostID: nil,
        command: "sleep 2",
        output: "",
        exitCode: 0,
        startedAt: Date(),
        durationSeconds: 2.5
    )
    let restored = try JSONDecoder().decode(
        ExecutionRecord.self,
        from: JSONEncoder().encode(record)
    )
    #expect(restored.durationSeconds == 2.5)
}

@Test("Conversation archives retain timing metadata and decode legacy JSON")
func conversationArchiveTimingCompatibility() throws {
    var message = ChatMessage(
        role: "tool",
        content: "完成",
        name: "run_command",
        toolCallID: "call"
    )
    message.commandResult = AICommandResultMetadata(
        status: .completed,
        command: "sleep 12",
        purpose: "等待",
        durationSeconds: 12.34
    )
    let record = ConversationRecord(
        id: UUID(),
        targetHostID: nil,
        targetName: "本机",
        title: "耗时",
        messages: [message],
        updatedAt: Date()
    )
    let restored = try JSONDecoder().decode(
        ConversationRecord.self,
        from: JSONEncoder().encode(record)
    )
    #expect(restored.messages.first?.commandResult?.durationSeconds == 12.34)

    let legacy = LegacyConversationRecord(
        id: UUID(),
        targetHostID: nil,
        targetName: "本机",
        title: "旧记录",
        messages: [ChatMessage(role: "tool", content: "旧输出", toolCallID: "call")],
        updatedAt: Date()
    )
    let legacyData = try JSONEncoder().encode([legacy])
    let decoded = try JSONDecoder().decode([ConversationRecord].self, from: legacyData)
    #expect(decoded.first?.messages.first?.content == "旧输出")
    #expect(decoded.first?.messages.first?.commandResult == nil)
}

private struct LegacyConversationRecord: Encodable {
    var id: UUID
    var targetHostID: UUID?
    var targetName: String
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var terminalSessionID: UUID? = nil
}
