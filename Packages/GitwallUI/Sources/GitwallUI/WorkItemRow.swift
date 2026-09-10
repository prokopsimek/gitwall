import GitwallCore
import SwiftUI

extension ItemPresentation.Tone {
    public var color: Color {
        switch self {
        case .positive: .green
        case .negative: .red
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

extension Color {
    /// Parses "RRGGBB" / "#RRGGBB"; returns nil for anything else.
    public init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// One line per item. Used by the popover list and by every widget size.
public struct WorkItemRow: View {
    public enum Style: Sendable {
        /// Title + repo + badges on one line (small / medium widgets).
        case compact
        /// Two lines with author, labels and counters (popover, large widgets).
        case regular
    }

    let item: WorkItem
    let avatar: Image?
    let style: Style
    let now: Date
    let isNew: Bool

    public init(item: WorkItem, avatar: Image?, style: Style = .regular, isNew: Bool = false, now: Date = Date()) {
        self.item = item
        self.avatar = avatar
        self.style = style
        self.isNew = isNew
        self.now = now
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            avatarView
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isNew {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            .accessibilityLabel("New")
                    }
                    Text(item.title)
                        .font(style == .compact ? .caption : .body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(ItemPresentation.age(of: item, now: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Image(systemName: ItemPresentation.kindSymbol(for: item.kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ItemPresentation.repoLabel(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if style == .regular {
                        Text(item.author.login)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    badges
                }
                if style == .regular, !item.labels.isEmpty || item.commentCount > 0 || item.additions != nil {
                    detailLine
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var avatarView: some View {
        let size: CGFloat = style == .compact ? 16 : 22
        Group {
            if let avatar {
                avatar.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .padding(.top, 1)
    }

    private var badges: some View {
        HStack(spacing: 3) {
            ForEach(ItemPresentation.badges(for: item)) { badge in
                Image(systemName: badge.symbol)
                    .font(.caption2)
                    .foregroundStyle(badge.tone.color)
                    .help(badge.text)
                    .accessibilityLabel(badge.text)
            }
        }
    }

    private var detailLine: some View {
        HStack(spacing: 6) {
            ForEach(item.labels.prefix(3), id: \.name) { label in
                Text(label.name)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background((Color(hex: label.colorHex) ?? .secondary).opacity(0.18), in: Capsule())
            }
            if item.labels.count > 3 {
                Text("+\(item.labels.count - 3)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if item.commentCount > 0 {
                Label("\(item.commentCount)", systemImage: "bubble.left")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let additions = item.additions, let deletions = item.deletions {
                Text("+\(additions)").font(.caption2).foregroundStyle(.green)
                Text("−\(deletions)").font(.caption2).foregroundStyle(.red)
            }
        }
    }
}
