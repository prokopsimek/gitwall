import Foundation
import Testing
@testable import GitwallUI

@Suite("Markdown blocks")
struct MarkdownBlocksTests {
    /// One line per block, so a whole document compares at a glance.
    private func describe(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case .heading(let level, let text): "h\(level) \(plain(text))"
            case .paragraph(let text): "p \(plain(text))"
            case .quote(let text): "> \(plain(text))"
            case .listItem(let marker, let depth, let text): "\(String(repeating: "  ", count: depth))\(describe(marker)) \(plain(text))"
            case .code(let language, let text): "code[\(language ?? "")] \(text)"
            case .table(let header, let rows): "table \(header.map(plain).joined(separator: "|")) / \(rows.map { $0.map(plain).joined(separator: "|") }.joined(separator: " / "))"
            case .details(let summary, let blocks): "details \(summary) { \(describe(blocks).joined(separator: "; ")) }"
            case .rule: "---"
            }
        }
    }

    private func describe(_ marker: MarkdownBlock.ListMarker) -> String {
        switch marker {
        case .bullet: "•"
        case .number(let number): "\(number)."
        case .task(let done): done ? "[x]" : "[ ]"
        case .continuation: "…"
        }
    }

    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    private func parse(_ source: String) -> [String] { describe(MarkdownBlock.parse(source)) }

    @Test("headings, paragraphs, quotes, rules and code blocks")
    func blocks() {
        #expect(parse("""
        # Title
        ## Sub

        First line
        same paragraph

        > quoted

        ---

        ```swift
        let a = 1
        ```
        """) == ["h1 Title", "h2 Sub", "p First line same paragraph", "> quoted", "---", "code[swift] let a = 1"])
    }

    @Test("lists keep their depth, numbers and task boxes")
    func lists() {
        #expect(parse("""
        - one
        - [ ] open task
        - [x] done task
          - nested

        1. first
        2. second
        """) == ["• one", "[ ] open task", "[x] done task", "  • nested", "1. first", "2. second"])
    }

    @Test("a second paragraph in a list item continues it without a new bullet")
    func continuation() {
        #expect(parse("- first\n\n  more of the first\n- second") == ["• first", "… more of the first", "• second"])
    }

    @Test("tables become rows of cells")
    func table() {
        #expect(parse("""
        | Step | Status |
        |---|---|
        | Base image | **done** |
        | Run | waiting |
        """) == ["table Step|Status / Base image|done / Run|waiting"])
    }

    @Test("inline emphasis, code and links stay in the text as attributes")
    func inline() throws {
        let blocks = MarkdownBlock.parse("Use **bold**, `code` and [the docs](https://example.com/docs).")
        guard case .paragraph(let text) = try #require(blocks.first) else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(plain(text) == "Use bold, code and the docs.")
        #expect(text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(text.runs.contains { $0.inlinePresentationIntent == .code })
        #expect(text.runs.contains { $0.link == URL(string: "https://example.com/docs") })
        #expect(text.runs.allSatisfy { $0.presentationIntent == nil })
    }

    @Test("a hard line break stays a line break")
    func hardBreak() {
        #expect(parse("one  \ntwo") == ["p one\ntwo"])
    }

    @Test("details collapse into a summary and their own blocks, nested ones too")
    func details() {
        #expect(parse("""
        Before

        <details>
        <summary>Plan (3 steps)</summary>

        1. Pin the image
        2. Rebuild

        <details><summary><b>Log</b></summary>

        ```
        error: arm64
        ```
        </details>
        </details>

        After
        """) == ["p Before", "details Plan (3 steps) { 1. Pin the image; 2. Rebuild; details Log { code[] error: arm64 } }", "p After"])
    }

    @Test("details without a summary are called Details")
    func detailsWithoutSummary() {
        #expect(parse("<details>\n\nhidden\n\n</details>") == ["details Details { p hidden }"])
    }

    @Test("HTML inside a code block is code, not a collapsible section")
    func detailsInCode() {
        #expect(parse("```html\n<details><summary>x</summary></details>\n```") == ["code[html] <details><summary>x</summary></details>"])
    }

    @Test("HTML comments are hidden, as on GitHub")
    func comments() {
        #expect(parse("Visible <!-- hidden -->\n\n<!--\nmulti\nline\n-->\nAfter") == ["p Visible", "p After"])
    }

    @Test("other HTML shows as its plain text; a line break tag breaks the line")
    func otherHTML() {
        #expect(parse("Line<br>two and <sub>small</sub> text") == ["p Line\ntwo and small text"])
        #expect(parse("<p align=\"center\">Centered <b>title</b></p>") == ["p Centered title"])
    }

    @Test("images become links named by their alt text")
    func images() throws {
        let markdown = MarkdownBlock.parse("![Screenshot](https://example.com/a.png)")
        guard case .paragraph(let text) = try #require(markdown.first) else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(plain(text) == "Screenshot")
        #expect(text.runs.contains { $0.link == URL(string: "https://example.com/a.png") })

        let html = MarkdownBlock.parse("<img src=\"https://example.com/b.png\" alt=\"Chart\" width=\"300\">")
        guard case .paragraph(let tag) = try #require(html.first) else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(plain(tag) == "Chart")
        #expect(tag.runs.contains { $0.link == URL(string: "https://example.com/b.png") })
    }

    @Test("an empty or blank text has no blocks")
    func empty() {
        #expect(MarkdownBlock.parse("").isEmpty)
        #expect(MarkdownBlock.parse(" \n\r\n").isEmpty)
    }

    @Test("Windows line endings read like Unix ones")
    func crlf() {
        #expect(parse("Fix for #679 \r\n\r\nSecond paragraph") == ["p Fix for #679", "p Second paragraph"])
    }
}
