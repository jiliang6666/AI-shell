import Foundation

/// A compatibility path for models that ask for a choice in prose instead of
/// invoking ask_user. It never invents choices or turns text into shell commands.
enum AITextQuestionParser {
    static func parse(_ text: String) -> AIUserQuestionArguments? {
        let blocks = MarkdownBlockParser.parse(text)
        let tail = max(0, blocks.count - 12)..<blocks.count
        guard let index = tail.last(where: { explicitRequest(in: blocks[$0]) != nil }),
              let question = explicitRequest(in: blocks[index]), question.count <= 800 else { return nil }

        var items: [String] = []
        var cursor = index + 1
        // One short explanatory paragraph may separate the question and options.
        if cursor < blocks.count, case .paragraph = blocks[cursor] { cursor += 1 }
        while cursor < blocks.count, case .listItem(_, let text, let depth) = blocks[cursor], depth == 0 {
            items.append(text)
            cursor += 1
        }
        if items.isEmpty {
            cursor = index - 1
            while cursor >= 0, case .listItem(_, let text, let depth) = blocks[cursor], depth == 0 {
                items.insert(text, at: 0)
                cursor -= 1
            }
        }
        // A request followed by further narrative is often instructions to the
        // user about another interface. Do not pause a completed explanation.
        guard index == blocks.count - 1 || (!items.isEmpty && cursor == blocks.count) else { return nil }
        let options: [AIUserQuestionArguments.Option]
        if (2...5).contains(items.count), items.allSatisfy({ $0.count <= 520 }) {
            options = items.enumerated().map { offset, item in
                let lines = item.components(separatedBy: "\n")
                let label = plain(lines[0])
                return .init(id: "choice-\(offset + 1)", label: label,
                             description: lines.count > 1 ? plain(lines.dropFirst().joined(separator: "\n")) : nil)
            }
            guard options.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 120 && ($0.description?.count ?? 0) <= 400 }) else { return nil }
        } else {
            guard items.isEmpty else { return nil }
            options = []
        }
        return AIUserQuestionArguments(question: plain(question), reason: "回答后继续当前任务。", options: options)
    }

    private static func explicitRequest(in block: MarkdownBlock) -> String? {
        let text: String
        switch block {
        case .paragraph(let lines): text = lines.last ?? ""
        case .heading(_, let value): text = value
        default: return nil // Quoted examples and fenced commands are never requests.
        }
        let normalized = plain(text).trimmingCharacters(in: .whitespaces)
        let authenticationTerms = ["密码", "私钥", "密钥", "验证码", "指纹", "password", "api key", "private key"]
        guard !authenticationTerms.contains(where: { normalized.localizedCaseInsensitiveContains($0) }) else { return nil }
        let pattern = #"^(?:请(?:你|您)?(?:先|明确)?(?:选择|确认|决定)|需要(?:你|您)(?:选择|确认|决定)|(?:你|您)(?:希望|想要).*(?:[?？]|选择)|(?:请)?回复.*(?:编号|选项|数字)|please\s+(?:choose|select|confirm)|which\s+(?:option|approach))"#
        return normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil ? nil : normalized
    }

    private static func plain(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else { return text }
        return String(attributed.characters)
    }
}
