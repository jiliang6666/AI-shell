import Foundation
import Testing
@testable import SwiftTerminal

@Test("The OpenCode Go session header is only sent to OpenCode endpoints")
@MainActor
func gatewaySessionHeaderTargetsOnlyOpenCode() throws {
    #expect(TerminalAIModel.requiresGatewaySessionHeader(
        try #require(URL(string: "https://opencode.ai/inference/go/openai/v1/chat/completions"))))
    #expect(TerminalAIModel.requiresGatewaySessionHeader(
        try #require(URL(string: "https://OPENCODE.AI/inference/go/v1/models"))))
    #expect(TerminalAIModel.requiresGatewaySessionHeader(
        try #require(URL(string: "https://zen.opencode.ai/v1/chat/completions"))))
    // Other gateways must not receive a header they know nothing about.
    #expect(!TerminalAIModel.requiresGatewaySessionHeader(
        try #require(URL(string: "https://api.deepseek.com/chat/completions"))))
    #expect(!TerminalAIModel.requiresGatewaySessionHeader(
        try #require(URL(string: "https://api.openai.com/v1/chat/completions"))))
    #expect(!TerminalAIModel.requiresGatewaySessionHeader(
        try #require(URL(string: "https://notopencode.ai.example.com/v1/chat/completions"))))
}

@Test("Model requests identify the application instead of the HTTP library")
@MainActor
func modelRequestsCarryOwnUserAgent() {
    let agent = TerminalAIModel.requestUserAgent
    #expect(agent.hasPrefix("Zhanqiao/"))
    // A generic library name is what agent gateways ask clients to avoid.
    #expect(!agent.lowercased().contains("cfnetwork"))
    #expect(!agent.lowercased().contains("urlsession"))
}
