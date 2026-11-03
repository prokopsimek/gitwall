import SwiftUI

/// Renders GitHub Markdown natively, block by block (see ``MarkdownBlock``). Text can be selected and copied; links
/// go through the environment's `openURL`, so the caller decides where they open.
public struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    public init(_ source: String) {
        blocks = MarkdownBlock.parse(source)
    }

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .paragraph(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 3)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                markerView(marker).frame(minWidth: 14, alignment: .trailing)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.caption, design: .monospaced)).padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    if !header.isEmpty {
                        GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Text($0.element).fontWeight(.semibold) } }
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text($0.element) } }
                    }
                }
                .padding(8)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        case .details(let summary, let inner):
            DisclosureGroup {
                MarkdownView(blocks: inner).padding(.top, 4)
            } label: {
                Text(summary).fontWeight(.medium)
            }
        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func markerView(_ marker: MarkdownBlock.ListMarker) -> some View {
        switch marker {
        case .bullet: Text("•").foregroundStyle(.secondary)
        case .number(let number): Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? Color.accentColor : .secondary)
                .accessibilityLabel(done ? "Done" : "Not done")
        case .continuation: Text(" ")
        }
    }
}
