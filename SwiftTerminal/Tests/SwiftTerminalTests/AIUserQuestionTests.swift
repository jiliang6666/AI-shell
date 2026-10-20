import Foundation
import Testing
@testable import SwiftTerminal

@Test("Question parsing rejects ambiguous options and accepts freeform questions")
func questionArgumentsValidation() {
    #expect(AIUserQuestionArguments.parse(#"{"question":"需要什么版本？","reason":"版本要求未提供。","options":[]}"#) != nil)
    #expect(AIUserQuestionArguments.parse(#"{"question":" ","reason":"needed","options":[]}"#) == nil)
    #expect(AIUserQuestionArguments.parse(#"{"question":"which","reason":"needed","options":[{"id":"a","label":"A"},{"id":"a","label":"B"}]}"#) == nil)
    #expect(AIUserQuestionArguments.parse(#"{"question":"which","reason":"needed","options":[{"id":"a","label":"A"}],"recommended_option_id":"missing"}"#) == nil)
    #expect(AIUserQuestionArguments.parse(#"{"question":"which","reason":"needed","options":[{"id":"a","label":" "}]}"#) == nil)
}

@Test("The chosen answer remains readable without JSON or numbered replies")
func questionAnswerPresentation() throws {
    let answer = AIUserAnswer(question: "安装方式？", selectedOptionID: "keep", selectedOption: "保留现有配置", text: "只更新依赖")
    let json = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
    #expect(AIUserAnswer.displayText(from: json) == "安装方式？\n保留现有配置\n只更新依赖")
}
