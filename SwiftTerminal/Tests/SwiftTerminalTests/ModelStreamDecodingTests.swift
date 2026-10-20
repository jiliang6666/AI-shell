import Foundation
import Testing
@testable import SwiftTerminal

@Test("Chat completion stream accepts ordinary text chunks and metadata-only events")
func chatStreamDecodesTextAndEmptyUsageChoices() throws {
    let decoder = JSONDecoder()
    let content = try decoder.decode(StreamChunk.self, from: Data(#"{"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}"#.utf8))
    let usage = try decoder.decode(StreamChunk.self, from: Data(#"{"choices":[],"usage":{"completion_tokens":1}}"#.utf8))

    #expect(content.choices.first?.delta?.content == "hello")
    #expect(usage.choices.isEmpty)
}

@Test("Chat completion stream accepts structured text content and sparse tool call fields")
func chatStreamDecodesContentPartsAndSparseToolCalls() throws {
    let chunk = try JSONDecoder().decode(
        StreamChunk.self,
        from: Data(#"{"choices":[{"delta":{"content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}],"tool_calls":[{"id":"call_1","function":{"name":"inspect_target","arguments":"{}"}}]}}]}"#.utf8)
    )

    #expect(chunk.choices.first?.delta?.content == "hello world")
    #expect(chunk.choices.first?.delta?.toolCalls?.first?.index == 0)
    #expect(chunk.choices.first?.delta?.toolCalls?.first?.function?.name == "inspect_target")
}

@Test("Stream events decode markdown fragments, response deltas, and ordinary JSON replies")
func modelStreamDecodesCommonResponseShapes() throws {
    let markdown = try ModelStreamEvent.decode(#"{"choices":[{"delta":{"content":[{"type":"text","text":{"value":"**Hello"}},{"type":"text","text":"** world"}]}}]}"#)
    let responseDelta = try ModelStreamEvent.decode(#"{"type":"response.output_text.delta","delta":"\n- item"}"#)
    let ordinaryJSON = try ModelStreamEvent.decode(#"{"choices":[{"message":{"role":"assistant","content":"Finished **answer**"}}]}"#)
    let metadata = try ModelStreamEvent.decode(#"{"type":"response.created","response":{"id":"r1"}}"#)

    #expect(markdown.text == "**Hello** world")
    #expect(responseDelta.text == "\n- item")
    #expect(ordinaryJSON.text == "Finished **answer**")
    #expect(metadata.text.isEmpty)
}

@Test("Stream events keep sparse tool arguments and reject service errors")
func modelStreamHandlesToolCallAndError() throws {
    let event = try ModelStreamEvent.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"inspect_target","arguments":"{}"}}]}}]}"#)
    #expect(event.toolCallDeltas.first?.function?.arguments == "{}")
    #expect(throws: ModelStreamDecodeFailure.self) {
        try ModelStreamEvent.decode(#"{"error":{"message":"model unavailable"}}"#)
    }
}

@Test("Non-JSON payloads are reported separately so the stream can continue")
func nonJSONPayloadIsRecoverable() throws {
    #expect(throws: ModelStreamDecodeFailure.self) {
        try ModelStreamEvent.decode("ping")
    }
    do {
        _ = try ModelStreamEvent.decode("data: not json")
        Issue.record("Expected an unparseable payload failure")
    } catch let failure as ModelStreamDecodeFailure {
        guard case .unparseable(let raw) = failure else {
            Issue.record("Expected .unparseable, received \(failure)")
            return
        }
        #expect(raw == "data: not json")
    }
}

@Test("Reasoning tokens never leak into visible answer text")
func reasoningContentIsIgnored() throws {
    let reasoningOnly = try ModelStreamEvent.decode(
        #"{"choices":[{"delta":{"content":null,"reasoning_content":"let me think"},"finish_reason":null}]}"#
    )
    let answer = try ModelStreamEvent.decode(
        ##"{"choices":[{"delta":{"content":"# 标题","reasoning_content":null},"finish_reason":null}]}"##
    )
    let unknownShape = try ModelStreamEvent.decode(
        #"{"output":[{"content":[{"text":"fallback text"}]}],"reasoning_content":"hidden"}"#
    )

    #expect(reasoningOnly.text.isEmpty)
    #expect(answer.text == "# 标题")
    #expect(unknownShape.text == "fallback text")
    #expect(!unknownShape.text.contains("hidden"))
}

@Test("Internal request identity is not serialized into model messages")
func chatMessageRequestIdentityStaysLocal() throws {
    var message = ChatMessage(role: "assistant", content: "answer")
    message.requestID = UUID()
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
    #expect(object?["requestID"] == nil)
    #expect(object?["request_id"] == nil)
    #expect(object?["content"] as? String == "answer")
}

@Test("A final usage chunk sent without a blank line is dispatched before [DONE]")
func adjacentFinalChunkAndDoneAreSeparated() {
    let usageChunk = #"{"choices":[{"index":0,"delta":{"content":"","reasoning_content":null},"finish_reason":"stop"}],"usage":{"total_tokens":1139}}"#
    #expect(TerminalAIModel.isCompleteEvent([usageChunk]))
    #expect(TerminalAIModel.isCompleteEvent(["[DONE]"]))
    // A pretty-printed payload must stay buffered until its final line arrives.
    #expect(!TerminalAIModel.isCompleteEvent(["{\"choices\":["]))
    #expect(TerminalAIModel.isCompleteEvent(["{\"choices\":[", "  {\"index\":0}", "]}"]))
}

@Test("Incomplete streaming Markdown remains readable before its closing delimiter arrives")
func partialMarkdownRemainsReadable() throws {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    let partial = try AttributedString(markdown: "**streaming", options: options)
    let complete = try AttributedString(markdown: "**streaming**", options: options)

    #expect(String(partial.characters).contains("streaming"))
    #expect(String(complete.characters) == "streaming")
}

@Test("Model profile library can add and edit several saved profiles")
func modelProfileStoreAddsAndEditsProfiles() throws {
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftTerminalModelEditTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let store = ModelProfileStore(directory: sandbox)
    let first = ModelProfile(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKey: "first-test-key")
    let second = ModelProfile(name: "Local", baseURL: "http://localhost:1234/v1", model: "qwen", apiKey: "second-test-key")
    let draft = ModelProfile(name: "Draft", baseURL: "https://api.example.com/v1")
    try store.saveAll([first, second, draft], activeID: first.id)

    var edited = second
    edited.name = "Local edited"
    edited.model = "qwen3"
    try store.saveAll([first, edited, draft], activeID: edited.id)

    #expect(try store.loadAll() == [first, edited, draft])
    #expect(store.active(from: [first, edited, draft]).id == edited.id)
    #expect(!draft.isConfigured)
}
