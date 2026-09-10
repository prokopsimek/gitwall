import GitwallCore
import GitwallUI
import OSLog
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "widget")

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

/// Reads config + snapshot from the App Group and applies the chosen preset. Never touches the network.
struct PresetTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PresetEntry { .placeholder }

    func snapshot(for configuration: SelectPresetIntent, in context: Context) async -> PresetEntry {
        context.isPreview ? .placeholder : load(configuration)
    }

    func timeline(for configuration: SelectPresetIntent, in context: Context) async -> Timeline<PresetEntry> {
        PresetEntry.timeline(load(configuration))
    }

    private func load(_ configuration: SelectPresetIntent) -> PresetEntry {
        PresetEntry.load(presetID: configuration.preset?.id)
    }
}

/// Serves the original static widget kind: always the first preset. Kept so widgets placed with early
/// builds keep working; new widgets use the configurable `GitwallWidget`.
struct LegacyTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PresetEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PresetEntry) -> Void) {
        completion(context.isPreview ? .placeholder : PresetEntry.load(presetID: nil))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PresetEntry>) -> Void) {
        completion(PresetEntry.timeline(PresetEntry.load(presetID: nil)))
    }
}

extension PresetEntry {
    /// The app reloads timelines after every sync; the timeline policy only keeps relative times fresh.
    static func timeline(_ entry: PresetEntry) -> Timeline<PresetEntry> {
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(next))
    }

    /// Reads config + snapshot from the App Group and applies the chosen preset (or the first one).
    static func load(presetID: UUID?) -> PresetEntry {
        let now = Date()
        guard let container = AppGroup.containerURL() else {
            log.error("App Group container unavailable in widget")
            return PresetEntry(date: now, preset: nil, items: [], fetchedAt: nil, staleAfter: 900, container: nil, problem: .containerUnavailable, attention: false, isDefaultPreset: true, presetCount: 0)
        }
        let config = (try? ConfigStore(directoryURL: container).load()) ?? .empty
        let snapshot = try? SnapshotStore(directoryURL: container).load()
        let staleAfter = config.settings.refreshInterval * 3

        guard !config.accounts.isEmpty else {
            return PresetEntry(date: now, preset: nil, items: [], fetchedAt: snapshot?.fetchedAt, staleAfter: staleAfter, container: container, problem: .noAccounts, attention: false, isDefaultPreset: true, presetCount: config.presets.count)
        }
        let chosen = presetID.flatMap { config.preset(id: $0) }
        let preset = chosen ?? config.presets.first
        guard let preset else {
            return PresetEntry(date: now, preset: nil, items: [], fetchedAt: snapshot?.fetchedAt, staleAfter: staleAfter, container: container, problem: .noPreset, attention: false, isDefaultPreset: true, presetCount: 0)
        }
        let items = snapshot.map { FilterEngine.items(matching: preset, in: $0.items, accounts: config.accounts, now: now) } ?? []
        let attention = snapshot?.accountStatus.values.contains { $0.state != .ok } ?? false
        log.info("Widget rendered preset \(preset.name, privacy: .public) with \(items.count) items")
        return PresetEntry(date: now, preset: preset, items: items, fetchedAt: snapshot?.fetchedAt, staleAfter: staleAfter, container: container, problem: nil, attention: attention, isDefaultPreset: chosen == nil, presetCount: config.presets.count)
    }
}

// MARK: - Views

struct GitwallWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PresetEntry

    /// Compact rows are ~34 pt with the divider; these counts fit the standard widget heights with margins.
    private var rowLimit: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 7
        case .systemExtraLarge: 14
        default: 3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if entry.problem == nil, entry.isDefaultPreset, entry.presetCount > 1, family != .systemSmall {
                Text("Right-click → Edit Widget to pick a preset")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let problem = entry.problem {
                problemView(problem)
            } else if family == .systemSmall {
                smallBody
            } else if entry.items.isEmpty {
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
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(headerURL)
    }

    private var headerURL: URL {
        entry.preset.map { DeepLink.view(id: $0.id).url } ?? DeepLink.refresh.url
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.preset?.icon ?? "arrow.triangle.pull")
                .foregroundStyle(.tint)
            Text(entry.preset?.name ?? "Gitwall")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if entry.problem == nil, family != .systemSmall {
                Text("\(entry.items.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 0)
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
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entry.items.count)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(entry.items.count == 1 ? "open item" : "open items")
                .font(.caption).foregroundStyle(.secondary)
            if let first = entry.items.first {
                Link(destination: DeepLink.item(id: first.id).url) {
                    Text(first.title)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private var rows: some View {
        let items = Array(entry.items.prefix(rowLimit))
        let columns = family == .systemExtraLarge ? 2 : 1
        let perColumn = Int((Double(items.count) / Double(columns)).rounded(.up))
        return HStack(alignment: .top, spacing: 16) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items.dropFirst(column * perColumn).prefix(perColumn)) { item in
                        Link(destination: DeepLink.item(id: item.id).url) {
                            WorkItemRow(
                                item: item,
                                avatar: AvatarCache.image(for: item.author.avatarURL, in: entry.container),
                                style: .compact,
                                now: entry.date
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        if item.id != items.last?.id { Divider() }
                    }
                    if column == columns - 1, entry.items.count > items.count {
                        Text("+\(entry.items.count - items.count) more")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

/// One widget per size so each entry in the gallery says what it shows.
struct PresetWidgetSpec {
    let kind: String
    let families: [WidgetFamily]
    let name: LocalizedStringResource
    let description: LocalizedStringResource

    init(kind: String, family: WidgetFamily, name: LocalizedStringResource, description: LocalizedStringResource) {
        self.init(kind: kind, families: [family], name: name, description: description)
    }

    init(kind: String, families: [WidgetFamily], name: LocalizedStringResource, description: LocalizedStringResource) {
        self.kind = kind
        self.families = families
        self.name = name
        self.description = description
    }

    static let all: [PresetWidgetSpec] = [
        PresetWidgetSpec(kind: AppGroup.widgetKindCounter, family: .systemSmall, name: "Gitwall Counter",
                         description: "How many items match a preset, plus the newest one. Small square."),
        PresetWidgetSpec(kind: AppGroup.widgetKindList, family: .systemMedium, name: "Gitwall List",
                         description: "The three latest items of a preset with review, checks and merge state."),
        PresetWidgetSpec(kind: AppGroup.widgetKindBoard, family: .systemLarge, name: "Gitwall Board",
                         description: "Up to nine items with labels, comments and changed lines."),
        PresetWidgetSpec(kind: AppGroup.widgetKindWideBoard, family: .systemExtraLarge, name: "Gitwall Wide Board",
                         description: "Two columns with up to eighteen items. Made for large desktops."),
        PresetWidgetSpec(kind: AppGroup.widgetKindAnySize, families: [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge],
                         name: "Gitwall (any size)",
                         description: "The same preset widget in one entry for every size, if you prefer to resize later. Counter, List, Board and Wide Board show the same content."),
    ]
}

extension PresetWidgetSpec {
    /// `Widget` types need a parameterless init, so each size is its own type built from a spec.
    @MainActor
    func configuration() -> some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPresetIntent.self, provider: PresetTimelineProvider()) { entry in
            GitwallWidgetView(entry: entry)
        }
        .configurationDisplayName(name)
        .description(description)
        .supportedFamilies(families)
    }
}

struct CounterWidget: Widget {
    var body: some WidgetConfiguration { PresetWidgetSpec.all[0].configuration() }
}

struct ListWidget: Widget {
    var body: some WidgetConfiguration { PresetWidgetSpec.all[1].configuration() }
}

struct BoardWidget: Widget {
    var body: some WidgetConfiguration { PresetWidgetSpec.all[2].configuration() }
}

struct WideBoardWidget: Widget {
    var body: some WidgetConfiguration { PresetWidgetSpec.all[3].configuration() }
}

struct AnySizeWidget: Widget {
    var body: some WidgetConfiguration { PresetWidgetSpec.all[4].configuration() }
}

struct GitwallLegacyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppGroup.legacyWidgetKind, provider: LegacyTimelineProvider()) { entry in
            GitwallWidgetView(entry: entry)
        }
        .configurationDisplayName("Gitwall – First Preset (legacy)")
        .description("Kept for widgets placed with early versions: always shows your first preset. New widgets should use Counter, List, Board or Wide Board.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

enum PreviewData {
    static let items: [WorkItem] = {
        let account = UUID()
        let now = Date()
        func pr(_ number: Int, _ repo: String, _ title: String, _ author: String, minutesAgo: Double, review: ReviewState, ci: CIState,
                merge: MergeState = .clean, draft: Bool = false, labels: [GitwallCore.Label] = [], comments: Int = 0, add: Int? = nil, del: Int? = nil) -> WorkItem {
            WorkItem(accountID: account, kind: .pullRequest, repoFullName: repo, number: number, title: title,
                     url: URL(string: "https://github.com")!, author: UserRef(login: author),
                     createdAt: now.addingTimeInterval(-minutesAgo * 60 - 86_400), updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                     isDraft: draft, labels: labels, commentCount: comments,
                     reviewState: review, ciState: ci, mergeState: merge, additions: add, deletions: del)
        }
        func issue(_ number: Int, _ repo: String, _ title: String, _ author: String, minutesAgo: Double, labels: [GitwallCore.Label] = [], comments: Int = 0) -> WorkItem {
            WorkItem(accountID: account, kind: .issue, repoFullName: repo, number: number, title: title,
                     url: URL(string: "https://github.com")!, author: UserRef(login: author),
                     createdAt: now.addingTimeInterval(-minutesAgo * 60 - 3 * 86_400), updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                     labels: labels, commentCount: comments)
        }
        return [
            pr(42, "dxheroes/mcp-gateway", "Add GitLab provider", "prokopsimek", minutesAgo: 9, review: .approved, ci: .success,
               labels: [GitwallCore.Label(name: "provider", colorHex: "0E8A16")], comments: 3, add: 120, del: 7),
            pr(17, "dxheroes/web", "Fix hero layout on narrow screens", "alice", minutesAgo: 75, review: .pending, ci: .failure, merge: .conflict, draft: true),
            issue(7, "dxheroes/mcp-gateway", "Widget shows stale data after sleep", "bob", minutesAgo: 60 * 26,
                  labels: [GitwallCore.Label(name: "bug", colorHex: "D73A4A")], comments: 1),
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

#Preview(as: .systemMedium) {
    ListWidget()
} timeline: {
    PresetEntry.placeholder
}

#Preview(as: .systemLarge) {
    BoardWidget()
} timeline: {
    PresetEntry.placeholder
}
