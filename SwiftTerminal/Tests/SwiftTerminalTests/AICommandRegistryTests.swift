import Foundation
import Testing
@testable import SwiftTerminal

@Test("Slash commands share a strict parser and reject paths, multiline and bad arguments")
func slashCommandParsing() {
    #expect(AISlashCommandParser.parse("/compact") == .success(.compact))
    #expect(AISlashCommandParser.parse("/context") == .success(.context))
    #expect(AISlashCommandParser.parse("/model") == .success(.model(nil)))
    #expect(AISlashCommandParser.parse("/compact extra") == .failure(.invalidArguments))
    #expect(AISlashCommandParser.parse("/model bad") == .failure(.invalidArguments))
    #expect(AISlashCommandParser.parse("/usr/bin/ls") == .failure(.unknownCommand))
    #expect(!AISlashCommandParser.isCandidate("/usr/bin/ls"))
    #expect(AISlashCommandParser.isCandidate("/compact extra"))
    #expect(!AISlashCommandParser.isCandidate("说明 /compact"))
    #expect(AISlashCommandParser.parse("/unknown") == .failure(.unknownCommand))
}

@Test("Context configuration enforces YAML ranges and defaults")
func contextConfigurationValidation() {
    var configuration = AIContextConfiguration.standard
    configuration.contextWindowOverride = 32768
    #expect((try? configuration.validated(contextWindow: nil)) != nil)
    configuration.contextWindowOverride = 1023
    #expect(throws: AISessionStoreError.invalidArguments) {
        try configuration.validated(contextWindow: nil)
    }
    configuration.contextWindowOverride = 32768
    configuration.keepRecentTurns = 0
    #expect(throws: AISessionStoreError.invalidArguments) {
        try configuration.validated(contextWindow: nil)
    }
}
