import Foundation
import Testing
@testable import SwiftTerminal

@Test("Assistant Markdown keeps block structure instead of one flat paragraph")
func markdownBlocksAreParsed() {
    let source = """
    ## 检查结果

    - 系统信息
    - 磁盘状态

    ```bash
    uname -a
    df -h
    ```
    """

    let blocks = MarkdownBlockParser.parse(source)

    #expect(blocks.count == 4)
    #expect(blocks[0] == .heading(level: 2, text: "检查结果"))
    #expect(blocks[1] == .listItem(marker: "•", text: "系统信息", depth: 0))
    #expect(blocks[2] == .listItem(marker: "•", text: "磁盘状态", depth: 0))
    guard case .codeBlock(let language, let code) = blocks[3] else {
        Issue.record("Expected a code block, received \(blocks[3])")
        return
    }
    #expect(language == "bash")
    #expect(code == "uname -a\ndf -h")
}

@Test("Lines without blank separators are still split into blocks")
func markdownToleratesMissingBlankLines() {
    let source = """
    环境确认
    - 只读检查系统
    - 只读检查磁盘
    """

    let blocks = MarkdownBlockParser.parse(source)

    #expect(blocks.count == 3)
    #expect(blocks[0] == .paragraph(["环境确认"]))
    #expect(blocks[1] == .listItem(marker: "•", text: "只读检查系统", depth: 0))
    #expect(blocks[2] == .listItem(marker: "•", text: "只读检查磁盘", depth: 0))
}

@Test("Hard line breaks inside a paragraph survive parsing")
func paragraphKeepsHardLineBreaks() {
    let blocks = MarkdownBlockParser.parse("第一行\n第二行\n第三行")

    #expect(blocks == [.paragraph(["第一行", "第二行", "第三行"])])
}

@Test("An unfinished code fence still renders as code while streaming")
func unfinishedFenceBecomesCodeBlock() {
    let blocks = MarkdownBlockParser.parse("```bash\nuname -a")

    #expect(blocks == [.codeBlock(language: "bash", code: "uname -a")])
}

@Test("Numbered lists, quotes and tables are recognised")
func orderedListsQuotesAndTables() {
    let numbered = MarkdownBlockParser.parse("1. 先检查\n2. 再执行")
    #expect(numbered == [
        .listItem(marker: "1.", text: "先检查", depth: 0),
        .listItem(marker: "2.", text: "再执行", depth: 0)
    ])

    let quote = MarkdownBlockParser.parse("> 注意：只读")
    #expect(quote == [.quote(["注意：只读"])])

    let table = MarkdownBlockParser.parse("| 项目 | 状态 |\n| --- | --- |\n| Docker | 未运行 |")
    #expect(table == [.table(header: ["项目", "状态"], rows: [["Docker", "未运行"]])])
}

@Test("A long answer is parsed completely, with nothing dropped")
func longAnswerKeepsEveryBlock() {
    let parsed = MarkdownBlockParser.parse((1...12).map { "第 \($0) 段内容" }.joined(separator: "\n\n"))

    #expect(parsed.count == 12)
    #expect(parsed.last == .paragraph(["第 12 段内容"]))
}

@Test("Pipes inside inline commands and escaped table cells do not split columns")
func markdownCommandTableKeepsPipes() {
    let blocks = MarkdownBlockParser.parse("| 命令 | 说明 |\n| --- | --- |\n| `ps aux | head` | A\\|B |")
    #expect(blocks == [.table(header: ["命令", "说明"], rows: [["`ps aux | head`", "A|B"]])])
}

@Test("Indented continuation lines stay attached to their list item")
func markdownListKeepsExplanation() {
    let blocks = MarkdownBlockParser.parse("1. 检查环境\n   保留已有配置。\n2. 安装依赖")
    #expect(blocks == [.listItem(marker: "1.", text: "检查环境\n保留已有配置。", depth: 0),
                       .listItem(marker: "2.", text: "安装依赖", depth: 0)])
}
