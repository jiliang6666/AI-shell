import Foundation

struct AIUserQuestionArguments: Codable, Equatable, Sendable {
    struct Option: Codable, Identifiable, Equatable, Sendable {
        var id: String
        var label: String
        var description: String?
    }

    var question: String
    var reason: String
    var options: [Option]
    var recommendedOptionID: String?

    enum CodingKeys: String, CodingKey {
        case question, reason, options
        case recommendedOptionID = "recommended_option_id"
    }

    static func parse(_ json: String) -> Self? {
        guard let data = json.data(using: .utf8), data.count <= 65_536,
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        value.question = value.question.trimmingCharacters(in: .whitespacesAndNewlines)
        value.reason = value.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.question.isEmpty, !value.reason.isEmpty,
              value.question.count <= 800, value.reason.count <= 800,
              value.options.count <= 5 else { return nil }
        value.options = value.options.map {
            Option(id: $0.id.trimmingCharacters(in: .whitespacesAndNewlines),
                   label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                   description: $0.description?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard Set(value.options.map(\.id)).count == value.options.count,
              value.options.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty && $0.label.count <= 120 && ($0.description?.count ?? 0) <= 400 }),
              value.recommendedOptionID == nil || value.options.contains(where: { $0.id == value.recommendedOptionID }) else { return nil }
        return value
    }
}

struct AIUserQuestion: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable { case tool, assistantText }
    let id = UUID()
    var callID: String
    var sessionID: UUID
    var turnID: UUID
    var requestID: UUID
    var arguments: AIUserQuestionArguments
    var source: Source = .tool
}

struct AIUserAnswer: Codable, Sendable {
    var question: String
    var selectedOptionID: String?
    var selectedOption: String?
    var text: String?

    enum CodingKeys: String, CodingKey {
        case question, text
        case selectedOptionID = "selected_option_id", selectedOption = "selected_option"
    }

    var displayText: String {
        [question, selectedOption, text].compactMap { $0 }.joined(separator: "\n")
    }

    static func displayText(from json: String) -> String {
        guard let answer = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return json }
        return answer.displayText
    }
}
