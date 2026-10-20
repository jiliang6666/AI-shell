import SwiftUI

/// A parsed Markdown block.
///
/// Block structure is kept so the transcript can draw headings, list markers,
/// code blocks and quotes. SwiftUI's `Text` renders inline Markdown attributes
/// but ignores block-level presentation intents, which is why Markdown answers
/// used to collapse into one flat paragraph.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    /// A paragraph keeps its hard line breaks.
    case paragraph([String])
    case listItem(marker: String, text: String, depth: Int)
    case codeBlock(language: String?, code: String)
    case quote([String])
    case divider
    case table(header: [String], rows: [[String]])

}

/// Line-oriented Markdown block parser tuned for streamed assistant answers:
/// incomplete input degrades to text instead of failing, and missing blank
/// lines between blocks are tolerated because models emit them that way.
enum MarkdownBlockParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceMarker(trimmed) {
                var code: [String] = []
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) { index += 1; break }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language,
                                         code: code.joined(separator: "\n")))
                continue
            }

            if let heading = headingMatch(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted))
                continue
            }

            if let table = tableMatch(lines: lines, index: index) {
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }

            if let item = listMatch(line) {
                var text = [item.text]
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                index += 1
                while index < lines.count {
                    let continuation = lines[index]
                    guard !continuation.trimmingCharacters(in: .whitespaces).isEmpty,
                          continuation.prefix(while: { $0 == " " || $0 == "\t" }).count > indent,
                          !startsNewBlock(lines: lines, index: index) else { break }
                    text.append(continuation.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.listItem(marker: item.marker, text: text.joined(separator: "\n"), depth: item.depth))
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let candidateTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty || startsNewBlock(lines: lines, index: index) { break }
                paragraph.append(candidateTrimmed)
                index += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
            }
        }

        return blocks
    }

    private static func startsNewBlock(lines: [String], index: Int) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        return fenceMarker(trimmed) != nil
            || headingMatch(trimmed) != nil
            || isDivider(trimmed)
            || trimmed.hasPrefix(">")
            || listMatch(lines[index]) != nil
            || tableMatch(lines: lines, index: index) != nil
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) { return marker }
        return nil
    }

    private static func headingMatch(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for marker in ["-", "*", "_"] where trimmed.allSatisfy({ String($0) == marker }) {
            return true
        }
        return false
    }

    private static func listMatch(_ line: String) -> (marker: String, text: String, depth: Int)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let depth = indent.count / 2
        let body = String(line.dropFirst(indent.count))
        guard let first = body.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            let rest = body.dropFirst()
            guard rest.hasPrefix(" ") else { return nil }
            return ("•", rest.trimmingCharacters(in: .whitespaces), depth)
        }

        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = body.dropFirst(digits.count)
        guard rest.hasPrefix(".") || rest.hasPrefix(")") else { return nil }
        let text = rest.dropFirst()
        guard text.hasPrefix(" ") else { return nil }
        return ("\(digits).", text.trimmingCharacters(in: .whitespaces), depth)
    }

    private static func tableMatch(lines: [String], index: Int) -> (block: MarkdownBlock, nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        let dividerLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|"), isTableDivider(dividerLine) else { return nil }

        let header = splitRow(headerLine)
        guard header.count == splitRow(dividerLine).count else { return nil }
        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, candidate.contains("|") else { break }
            rows.append(splitRow(candidate))
            cursor += 1
        }
        return (.table(header: header, rows: rows), cursor)
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            guard cell.count >= 3 else { return false }
            return cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitRow(_ line: String) -> [String] {
        var value = line
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|"), value.dropLast().reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2) {
            value.removeLast()
        }
        var cells: [String] = []
        var cell = ""
        var codeDelimiter = 0
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                cell.append("|")
                index += 2
                continue
            }
            if character == "`" {
                var end = index + 1
                while end < characters.count, characters[end] == "`" { end += 1 }
                let count = end - index
                if codeDelimiter == 0 { codeDelimiter = count }
                else if codeDelimiter == count { codeDelimiter = 0 }
                cell += String(repeating: "`", count: count)
                index = end
                continue
            }
            if character == "|", codeDelimiter == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            index += 1
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

/// Draws parsed Markdown blocks.
struct MarkdownBlockListView: View {
    let blocks: [MarkdownBlock]
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text, size: headingSize(level))
                .fontWeight(.semibold)

        case .paragraph(let lines):
            inlineText(lines.joined(separator: "\n"), size: fontSize)
                .fixedSize(horizontal: false, vertical: true)

        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                inlineText(text, size: fontSize)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .font(.system(size: max(9, fontSize - 4), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code)
                        .font(.system(size: max(10, fontSize - 1), design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        case .quote(let lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                inlineText(lines.joined(separator: "\n"), size: fontSize)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .divider:
            Divider()

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inlineText(cell, size: max(10, fontSize - 1)).fontWeight(.semibold)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineText(cell, size: max(10, fontSize - 1))
                            }
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    /// Inline-only parsing keeps `**bold**`, `code` and links working without
    /// re-interpreting block syntax that was already consumed.
    private func inlineText(_ source: String, size: Double) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed).font(.system(size: size))
        }
        return Text(source).font(.system(size: size))
    }

    private func headingSize(_ level: Int) -> Double {
        switch level {
        case 1: return fontSize + 5
        case 2: return fontSize + 3
        case 3: return fontSize + 1
        default: return fontSize
        }
    }
}

/// Parses a Markdown string and draws it.
struct MarkdownBlockView: View, Equatable {
    let markdown: String
    let fontSize: Double

    var body: some View {
        MarkdownBlockListView(blocks: MarkdownBlockParser.parse(markdown), fontSize: fontSize)
    }
}
