import Foundation

/// One block of a GitHub description or comment, ready for ``MarkdownView``. Parsed natively: Foundation's Markdown
/// parser (`interpretedSyntax: .full`) for the blocks and inline styles, plus what it leaves to the caller. A
/// `<details>` block becomes a collapsible ``details(summary:blocks:)``, HTML comments are hidden as on GitHub, other
/// HTML shows as its text, and images become links named by their alt text. No third-party dependency.
public enum MarkdownBlock: Hashable, Sendable {
    public enum ListMarker: Hashable, Sendable {
        case bullet
        case number(Int)
        case task(done: Bool)
        /// A further paragraph of the list item above: indented, without a marker.
        case continuation
    }

    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case quote(AttributedString)
    /// `depth` is 0 for a top-level item.
    case listItem(ListMarker, depth: Int, text: AttributedString)
    case code(language: String?, text: String)
    case table(header: [AttributedString], rows: [[AttributedString]])
    case details(summary: String, blocks: [MarkdownBlock])
    case rule

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return MarkdownSegments.split(normalized).flatMap { segment -> [MarkdownBlock] in
            switch segment {
            case .markdown(let text): MarkdownRuns.blocks(text)
            case .details(let summary, let body): [.details(summary: summary, blocks: parse(body))]
            }
        }
    }
}

/// Splits a source into Markdown and `<details>` sections, outside code fences, and drops HTML comments on the way.
enum MarkdownSegments {
    enum Segment: Equatable {
        case markdown(String)
        case details(summary: String, body: String)
    }

    static func split(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        var markdown: [String] = []
        var details: [String] = []
        var depth = 0
        var fence: String?
        var inComment = false

        func flushMarkdown() {
            let text = markdown.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.markdown(text)) }
            markdown = []
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            var line = rawLine
            if fence == nil {
                line = stripComments(line, inComment: &inComment)
                if inComment, line.trimmingCharacters(in: .whitespaces).isEmpty, !rawLine.contains("-->") { continue }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if let marker = fenceMarker(trimmed) {
                fence = marker
            } else {
                let lower = trimmed.lowercased()
                let opens = occurrences(of: "<details", in: lower)
                let closes = occurrences(of: "</details>", in: lower)
                if depth == 0, opens > 0 {
                    flushMarkdown()
                    depth = opens - closes
                    details = [line]
                    if depth <= 0 {
                        segments.append(detailsSegment(details))
                        depth = 0
                    }
                    continue
                }
                if depth > 0 {
                    depth += opens - closes
                    details.append(line)
                    if depth <= 0 {
                        segments.append(detailsSegment(details))
                        depth = 0
                    }
                    continue
                }
            }
            if depth > 0 { details.append(line) } else { markdown.append(line) }
        }
        if depth > 0 { segments.append(detailsSegment(details)) }
        flushMarkdown()
        return segments
    }

    /// ```` ``` ```` or `~~~` that opens a fence, as typed (closing needs at least as many).
    private static func fenceMarker(_ line: String) -> String? {
        for character in ["`", "~"] {
            let marker = String(line.prefix { String($0) == character })
            if marker.count >= 3 { return marker }
        }
        return nil
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Removes `<!-- … -->`, which may span lines; `inComment` carries an open comment to the next line.
    private static func stripComments(_ line: String, inComment: inout Bool) -> String {
        var rest = Substring(line)
        var kept = ""
        while !rest.isEmpty {
            if inComment {
                guard let end = rest.range(of: "-->") else { return kept }
                rest = rest[end.upperBound...]
                inComment = false
            } else if let start = rest.range(of: "<!--") {
                kept += rest[..<start.lowerBound]
                rest = rest[start.upperBound...]
                inComment = true
            } else {
                kept += rest
                rest = ""
            }
        }
        return kept
    }

    /// Strips the outer `<details>` and `</details>` and takes the first `<summary>` as the title.
    private static func detailsSegment(_ lines: [String]) -> Segment {
        var text = lines.joined(separator: "\n")
        if let open = text.range(of: "<details[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(open)
        }
        if let close = text.range(of: "</details>", options: [.caseInsensitive, .backwards]) {
            text.removeSubrange(close)
        }
        var summary = "Details"
        if let range = text.range(of: "<summary[^>]*>[\\s\\S]*?</summary>", options: [.regularExpression, .caseInsensitive]) {
            let title = HTMLText.plain(String(text[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { summary = title }
            text.removeSubrange(range)
        }
        return .details(summary: summary, body: text)
    }
}

/// Turns Foundation's parse of one Markdown segment into blocks, run by run.
enum MarkdownRuns {
    static func blocks(_ source: String) -> [MarkdownBlock] {
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return [.paragraph(AttributedString(source))]
        }

        var blocks: [MarkdownBlock] = []
        var group: [AttributedString.Runs.Run] = []
        var groupKey: Int?
        var lastListItem: Int?

        func flush() {
            defer { group = [] }
            guard let first = group.first else { return }
            guard let intent = first.presentationIntent else {
                // Block HTML: its text, with images as links.
                let text = inline(group, in: parsed)
                if !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.paragraph(trimmed(text)))
                }
                return
            }
            if let block = block(for: group, intent: intent, in: parsed, lastListItem: &lastListItem) {
                blocks.append(block)
            }
        }

        for run in parsed.runs {
            let key = run.presentationIntent.map(blockKey) ?? -1
            if key != groupKey || key == -1 && !group.isEmpty && run.inlinePresentationIntent != group.last?.inlinePresentationIntent {
                flush()
                groupKey = key
            }
            group.append(run)
        }
        flush()
        return blocks
    }

    /// The identity runs of one block share: the table for table cells, otherwise the innermost block.
    private static func blockKey(_ intent: PresentationIntent) -> Int {
        if let table = intent.components.first(where: { if case .table = $0.kind { true } else { false } }) {
            return table.identity
        }
        return intent.components.first?.identity ?? -1
    }

    private static func block(
        for runs: [AttributedString.Runs.Run],
        intent: PresentationIntent,
        in parsed: AttributedString,
        lastListItem: inout Int?
    ) -> MarkdownBlock? {
        let components = intent.components
        if components.contains(where: { if case .table = $0.kind { true } else { false } }) {
            return table(runs, in: parsed)
        }
        guard let innermost = components.first else { return nil }
        switch innermost.kind {
        case .header(let level):
            return .heading(level: level, text: trimmed(inline(runs, in: parsed)))
        case .codeBlock(let language):
            var text = runs.map { String(parsed[$0.range].characters) }.joined()
            if text.hasSuffix("\n") { text.removeLast() }
            return .code(language: language.flatMap { $0.isEmpty ? nil : $0 }, text: text)
        case .thematicBreak:
            return .rule
        default:
            break
        }

        let text = trimmed(inline(runs, in: parsed))
        if components.contains(where: { $0.kind == .blockQuote }) { return .quote(text) }
        guard let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }) else {
            return .paragraph(text)
        }
        let item = components[itemIndex]
        let depth = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count - 1
        defer { lastListItem = item.identity }
        if lastListItem == item.identity { return .listItem(.continuation, depth: max(0, depth), text: text) }

        var marker = MarkdownBlock.ListMarker.bullet
        if case .listItem(let ordinal) = item.kind,
           components.indices.contains(itemIndex + 1), components[itemIndex + 1].kind == .orderedList {
            marker = .number(ordinal)
        }
        for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where String(text.characters).hasPrefix(prefix) {
            var rest = text
            rest.removeSubrange(rest.startIndex..<rest.index(rest.startIndex, offsetByCharacters: prefix.count))
            return .listItem(.task(done: done), depth: max(0, depth), text: rest)
        }
        return .listItem(marker, depth: max(0, depth), text: text)
    }

    private static func table(_ runs: [AttributedString.Runs.Run], in parsed: AttributedString) -> MarkdownBlock {
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        var cells: [(row: Int, cell: Int, runs: [AttributedString.Runs.Run])] = []
        for run in runs {
            guard let components = run.presentationIntent?.components,
                  let cell = components.first(where: { if case .tableCell = $0.kind { true } else { false } }),
                  let row = components.first(where: { $0.kind == .tableHeaderRow || { if case .tableRow = $0.kind { true } else { false } }($0) })
            else { continue }
            if let last = cells.last, last.row == row.identity, last.cell == cell.identity {
                cells[cells.count - 1].runs.append(run)
            } else {
                cells.append((row.identity, cell.identity, [run]))
            }
        }
        var rowOrder: [Int] = []
        var byRow: [Int: [AttributedString]] = [:]
        var headerRow: Int?
        for entry in cells {
            if byRow[entry.row] == nil { rowOrder.append(entry.row) }
            byRow[entry.row, default: []].append(trimmed(inline(entry.runs, in: parsed)))
            if headerRow == nil, entry.runs.first?.presentationIntent?.components.contains(where: { $0.kind == .tableHeaderRow }) == true {
                headerRow = entry.row
            }
        }
        for row in rowOrder {
            if row == headerRow { header = byRow[row] ?? [] } else { rows.append(byRow[row] ?? []) }
        }
        return .table(header: header, rows: rows)
    }

    /// The runs of one block as inline text: block structure dropped, soft breaks as spaces, `<br>` as a line break,
    /// other inline HTML as its text, images as links.
    private static func inline(_ runs: [AttributedString.Runs.Run], in parsed: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(parsed[run.range])
            piece.presentationIntent = nil
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.softBreak) {
                result += AttributedString(" ")
                continue
            }
            if intent.contains(.inlineHTML) || intent.contains(.blockHTML) {
                result += HTMLText.attributed(String(piece.characters))
                continue
            }
            if let image = run.imageURL {
                let alt = String(piece.characters)
                piece = AttributedString(alt.isEmpty ? "image" : alt)
                piece.link = image
            }
            result += piece
        }
        return result
    }

    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var text = text
        while let first = text.characters.first, first.isWhitespace {
            text.removeSubrange(text.startIndex..<text.index(afterCharacter: text.startIndex))
        }
        while let last = text.characters.last, last.isWhitespace {
            text.removeSubrange(text.index(beforeCharacter: text.endIndex)..<text.endIndex)
        }
        return text
    }
}

/// HTML that is not `<details>`: shown as its text, `<br>` as a line break, `<img>` as a link.
enum HTMLText {
    static func plain(_ html: String) -> String {
        String(attributed(html).characters)
    }

    static func attributed(_ html: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            result += AttributedString(decode(String(rest[..<open])))
            guard let close = rest[open...].firstIndex(of: ">") else {
                rest = rest[open...]
                break
            }
            let tag = String(rest[open...close])
            let lower = tag.lowercased()
            if lower.hasPrefix("<br") {
                result += AttributedString("\n")
            } else if lower.hasPrefix("<img"), let source = attribute("src", in: tag).flatMap(URL.init(string:)) {
                var link = AttributedString(attribute("alt", in: tag).flatMap { $0.isEmpty ? nil : $0 } ?? "image")
                link.link = source
                result += link
            }
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(decode(String(rest)))
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)\\s*=\\s*\"[^\"]*\"", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let value = tag[range]
        guard let start = value.firstIndex(of: "\"") else { return nil }
        return String(value[value.index(after: start)...].dropLast())
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
