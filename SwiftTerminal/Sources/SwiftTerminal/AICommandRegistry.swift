import Foundation

struct AICommandDescriptor: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var syntax: String
}

enum AISlashCommand: Equatable {
    case compact
    case model(UUID?)
    case context
}

enum AISlashCommandParser {
    static let commands = [
        AICommandDescriptor(id: "compact", title: "压缩上下文", syntax: "/compact"),
        AICommandDescriptor(id: "model", title: "模型", syntax: "/model [profileID]"),
        AICommandDescriptor(id: "context", title: "上下文管理", syntax: "/context")
    ]

    static func parse(_ input: String) -> Result<AISlashCommand, AIErrorCode> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), !trimmed.contains("\r"),
              let firstWhitespace = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            guard !trimmed.contains("\n"), !trimmed.contains("\r") else { return .failure(.unknownCommand) }
            return parseCommand(trimmed, arguments: [])
        }
        let command = String(trimmed[..<firstWhitespace])
        let argumentText = trimmed[trimmed.index(after: firstWhitespace)...]
        let arguments = argumentText.split(whereSeparator: \.isWhitespace).map(String.init)
        return parseCommand(command, arguments: arguments)
    }

    static func isCandidate(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), !trimmed.contains("\r"),
              let token = trimmed.split(whereSeparator: \.isWhitespace).first else { return false }
        return token.range(of: #"^/[a-z][a-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    private static func parseCommand(_ token: String, arguments: [String]) -> Result<AISlashCommand, AIErrorCode> {
        guard token.range(of: #"^/[a-z][a-z0-9_-]*$"#, options: .regularExpression) != nil else {
            return .failure(.unknownCommand)
        }
        let name = String(token.dropFirst())
        switch name {
        case "compact":
            return arguments.isEmpty ? .success(.compact) : .failure(.invalidArguments)
        case "context":
            return arguments.isEmpty ? .success(.context) : .failure(.invalidArguments)
        case "model":
            guard arguments.count <= 1 else { return .failure(.invalidArguments) }
            guard arguments.isEmpty else {
                guard let id = UUID(uuidString: arguments[0]) else { return .failure(.invalidArguments) }
                return .success(.model(id))
            }
            return .success(.model(nil))
        default:
            return .failure(.unknownCommand)
        }
    }
}

enum AICommandResult: Equatable {
    case completed(String)
    case openModels
    case openContext
    case noChange(String)
}
