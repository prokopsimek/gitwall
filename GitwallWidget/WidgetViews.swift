import GitwallCore
import GitwallUI
import SwiftUI
import WidgetKit

// Compiled into the widget extension and, for `--debug-demo-render`, into the app (see project.yml).

struct PresetEntry: TimelineEntry {
    enum Problem {
        case containerUnavailable
        case noAccounts
        case noPreset
    }

    let date: Date
    let preset: Preset?
    let items: [WorkItem]
    let fetchedAt: Date?
    let staleAfter: TimeInterval
    let container: URL?
    let problem: Problem?
    let attention: Bool
    /// True when the user has not picked a preset for this widget instance yet.
    let isDefaultPreset: Bool
    let presetCount: Int
    /// No account is connected yet, so these rows are `DemoData`. Declared with a default so the existing
    /// constructions stay as they are.
    var isSample: Bool = false

    var isStale: Bool {
        guard let fetchedAt else { return false }
        return date.timeIntervalSince(fetchedAt) > staleAfter
    }

    static let placeholder = PresetEntry(
        date: .now, preset: Preset(name: "Waiting for review", icon: "eye"),
        items: PreviewData.items, fetchedAt: .now, staleAfter: 900, container: nil, problem: nil, attention: false,
        isDefaultPreset: false, presetCount: 3
    )
}

// MARK: - Views

struct GitwallWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: PresetEntry
    /// Set when rendered outside WidgetKit (demo screenshots); widgets use the environment value.
    private let explicitFamily: WidgetFamily?

    init(entry: PresetEntry, family: WidgetFamily? = nil) {
        self.entry = entry
        explicitFamily = family
    }

    private var family: WidgetFamily { explicitFamily ?? environmentFamily }

    var body: some View {
        TileView(
            icon: entry.preset?.icon ?? "arrow.triangle.pull",
            title: entry.preset?.name ?? "Gitwall",
            count: entry.problem == nil ? entry.items.count : nil,
            items: entry.items,
            size: TileSize(family),
            now: entry.date,
            avatar: { AvatarCache.image(for: $0.author.avatarURL, in: entry.container) },
            wrap: { ItemLink(url: DeepLink.item(id: $0.id).url) },
            replacement: entry.problem.map(problemView)
        ) {
            headerTrailing
        } notice: {
            notice
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(headerURL)
    }

    private var headerURL: URL {
        entry.preset.map { DeepLink.view(id: $0.id).url } ?? DeepLink.refresh.url
    }

    @ViewBuilder
    private var headerTrailing: some View {
        if entry.attention {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        }
        if family != .systemSmall {
            if let fetchedAt = entry.fetchedAt {
                Text(ItemPresentation.compactAge(since: fetchedAt, now: entry.date))
                    .font(.caption2)
                    .foregroundStyle(entry.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            Link(destination: DeepLink.refresh.url) {
                Image(systemName: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Refresh")
        }
    }

    @ViewBuilder
    private var notice: some View {
        if entry.isSample, family != .systemSmall {
            Link(destination: DeepLink.settings(tab: "accounts").url) {
                Text("Sample data · connect an account")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        if entry.problem == nil, !entry.isSample, entry.isDefaultPreset, entry.presetCount > 1, family != .systemSmall {
            Text("Right-click → Edit Widget to pick a preset")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func problemView(_ problem: PresetEntry.Problem) -> some View {
        Spacer()
        VStack(spacing: 6) {
            switch problem {
            case .containerUnavailable:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                Text("Shared container unavailable").font(.caption)
            case .noAccounts:
                Link(destination: DeepLink.settings(tab: "accounts").url) {
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(.secondary)
                        Text("Connect an account").font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .noPreset:
                Link(destination: DeepLink.settings(tab: "presets").url) {
                    VStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.secondary)
                        Text("Create a preset").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        Spacer()
    }
}

extension TileSize {
    /// The tile of the same size as a widget of this family.
    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        case .systemExtraLarge: self = .extraLarge
        default: self = .medium
        }
    }
}

/// An item in a widget opens through a `gitwall://` link.
private struct ItemLink: ViewModifier {
    let url: URL

    func body(content: Content) -> some View {
        Link(destination: url) { content }
            .buttonStyle(.plain)
    }
}

enum PreviewData {
    static let items: [WorkItem] = {
        let account = UUID()
        let now = Date()
        func pr(_ number: Int, _ repo: String, _ title: String, _ author: String, minutesAgo: Double, review: ReviewState, ci: CIState,
                merge: MergeState = .clean, draft: Bool = false, labels: [GitwallCore.Label] = [], comments: Int = 0, add: Int? = nil, del: Int? = nil,
                priority: Priority? = nil) -> WorkItem {
            WorkItem(accountID: account, kind: .pullRequest, repoFullName: repo, number: number, title: title,
                     url: URL(string: "https://github.com")!, author: UserRef(login: author),
                     createdAt: now.addingTimeInterval(-minutesAgo * 60 - 86_400), updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                     isDraft: draft, labels: labels, commentCount: comments,
                     reviewState: review, ciState: ci, mergeState: merge, additions: add, deletions: del, projectPriority: priority)
        }
        func issue(_ number: Int, _ repo: String, _ title: String, _ author: String, minutesAgo: Double, labels: [GitwallCore.Label] = [], comments: Int = 0,
                   priority: Priority? = nil) -> WorkItem {
            WorkItem(accountID: account, kind: .issue, repoFullName: repo, number: number, title: title,
                     url: URL(string: "https://github.com")!, author: UserRef(login: author),
                     createdAt: now.addingTimeInterval(-minutesAgo * 60 - 3 * 86_400), updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                     labels: labels, commentCount: comments, projectPriority: priority)
        }
        return [
            pr(42, "dxheroes/mcp-gateway", "Add GitLab provider", "prokopsimek", minutesAgo: 9, review: .approved, ci: .success,
               labels: [GitwallCore.Label(name: "provider", colorHex: "0E8A16")], comments: 3, add: 120, del: 7),
            pr(17, "dxheroes/web", "Fix hero layout on narrow screens", "alice", minutesAgo: 75, review: .pending, ci: .failure, merge: .conflict, draft: true,
               priority: .p1),
            issue(7, "dxheroes/mcp-gateway", "Widget shows stale data after sleep", "bob", minutesAgo: 60 * 26,
                  labels: [GitwallCore.Label(name: "bug", colorHex: "D73A4A")], comments: 1, priority: .p0),
            pr(311, "dxheroes/dx-scanner", "Bump TypeScript to 5.9 and fix strict warnings", "renovate", minutesAgo: 60 * 30, review: ReviewState.none, ci: .running,
               labels: [GitwallCore.Label(name: "dependencies", colorHex: "0366D6")]),
            pr(88, "dxheroes/knowledge-base", "Document the OAuth device flow", "carol", minutesAgo: 60 * 41, review: .changesRequested, ci: .success, comments: 5, add: 64, del: 3),
            issue(102, "dxheroes/web", "Pricing page renders twice on first load", "dave", minutesAgo: 60 * 50,
                  labels: [GitwallCore.Label(name: "bug", colorHex: "D73A4A"), GitwallCore.Label(name: "frontend", colorHex: "FBCA04")], comments: 2),
            pr(203, "dxheroes/mcp-gateway", "Retry failed audits with exponential backoff", "erin", minutesAgo: 60 * 70, review: .approved, ci: .success, add: 210, del: 48),
            pr(9, "prokopsimek/gitwall", "Widget: compact rows for medium size", "prokopsimek", minutesAgo: 60 * 90, review: .pending, ci: .success, draft: true),
            issue(15, "dxheroes/dx-scanner", "Support Bitbucket Data Center", "frank", minutesAgo: 60 * 120,
                  labels: [GitwallCore.Label(name: "enhancement", colorHex: "A2EEEF")], comments: 8),
        ]
    }()
}
