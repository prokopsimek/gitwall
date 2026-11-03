import GitwallCore
import SwiftUI

/// Which items a tile lists, column by column, and how many it leaves out.
public struct TileRows: Equatable, Sendable {
    /// One column, or two for an extra large tile with the first one fuller.
    public let columns: [[WorkItem]]
    /// Items that match but do not fit, for the "+N more" line.
    public let hidden: Int

    public init(items: [WorkItem], size: TileSize) {
        let shown = Array(items.prefix(size.rowLimit))
        let count = size == .extraLarge ? 2 : 1
        let perColumn = Int((Double(shown.count) / Double(count)).rounded(.up))
        columns = (0..<count).map { column in Array(shown.dropFirst(column * perColumn).prefix(perColumn)) }
        hidden = items.count - shown.count
    }

    /// The listed items in reading order, column after column.
    public var visible: [WorkItem] { columns.flatMap(\.self) }
}

/// One preset as a tile: a header with the icon, the name and the count, then the items in compact rows, or the
/// count in large type at the small size. The desktop widgets and the Walls window draw the same tile; WidgetKit
/// stays out of here, so each caller wraps the rows and adds its own extras.
public struct TileView<Trailing: View, Notice: View, Replacement: View, ItemWrapper: ViewModifier>: View {
    let icon: String
    let title: String
    let count: Int?
    let items: [WorkItem]
    let size: TileSize
    let now: Date
    let avatar: (WorkItem) -> Image?
    let isNew: (WorkItem) -> Bool
    let wrap: (WorkItem) -> ItemWrapper
    let headerAction: (() -> Void)?
    let replacement: Replacement?
    let trailing: Trailing
    let notice: Notice

    /// - Parameters:
    ///   - count: The number next to the title; nil hides it. The small size never shows it, its body is the count.
    ///   - wrap: Makes an item clickable: a link in a widget, selection and activation in the Walls window.
    ///   - headerAction: Makes the icon, title and count a button.
    ///   - replacement: Shown instead of the items, for a widget that has nothing to show yet.
    ///   - trailing: After the title, at the right edge of the header.
    ///   - notice: Between the header and the items.
    public init(
        icon: String,
        title: String,
        count: Int?,
        items: [WorkItem],
        size: TileSize,
        now: Date,
        avatar: @escaping (WorkItem) -> Image?,
        isNew: @escaping (WorkItem) -> Bool = { _ in false },
        wrap: @escaping (WorkItem) -> ItemWrapper,
        headerAction: (() -> Void)? = nil,
        replacement: Replacement?,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder notice: () -> Notice
    ) {
        self.icon = icon
        self.title = title
        self.count = count
        self.items = items
        self.size = size
        self.now = now
        self.avatar = avatar
        self.isNew = isNew
        self.wrap = wrap
        self.headerAction = headerAction
        self.replacement = replacement
        self.trailing = trailing()
        self.notice = notice()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            notice
            if let replacement {
                replacement
            } else if size == .small {
                smallBody
            } else if items.isEmpty {
                Spacer()
                Text("Nothing to show").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                rows
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let headerAction {
                Button(action: headerAction) {
                    HStack(spacing: 6) { headerTitle }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                headerTitle
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder
    private var headerTitle: some View {
        Image(systemName: icon)
            .foregroundStyle(.tint)
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        if let count, size != .small {
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(items.count)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(items.count == 1 ? "open item" : "open items")
                .font(.caption).foregroundStyle(.secondary)
            if let first = items.first {
                Text(first.title)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .modifier(wrap(first))
            }
        }
    }

    private var rows: some View {
        let rows = TileRows(items: items, size: size)
        let last = rows.visible.last?.id
        return HStack(alignment: .top, spacing: 16) {
            ForEach(rows.columns.indices, id: \.self) { column in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows.columns[column]) { item in
                        WorkItemRow(item: item, avatar: avatar(item), style: .compact, isNew: isNew(item), now: now)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(wrap(item))
                        if item.id != last { Divider() }
                    }
                    if column == rows.columns.count - 1, rows.hidden > 0 {
                        Text("+\(rows.hidden) more")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
