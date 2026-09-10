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

    private var rowLimit: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 9
        case .systemExtraLarge: 18
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
            if entry.problem == nil {
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
                    Text(fetchedAt, style: .relative)
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
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items.dropFirst(column * perColumn).prefix(perColumn)) { item in
                        Link(destination: DeepLink.item(id: item.id).url) {
                            WorkItemRow(
                                item: item,
                                avatar: AvatarCache.image(for: item.author.avatarURL, in: entry.container),
                                style: family == .systemMedium ? .compact : .regular,
                                now: entry.date
                            )
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

struct GitwallWidget: Widget {
    static let kind = AppGroup.widgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectPresetIntent.self, provider: PresetTimelineProvider()) { entry in
            GitwallWidgetView(entry: entry)
        }
        .configurationDisplayName("Gitwall")
        .description("Pull requests and issues for a preset you choose. Add several widgets, each with its own preset and size.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct GitwallLegacyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppGroup.legacyWidgetKind, provider: LegacyTimelineProvider()) { entry in
            GitwallWidgetView(entry: entry)
        }
        .configurationDisplayName("Gitwall – First Preset")
        .description("Always shows your first preset. Use the configurable Gitwall widget to pick a different one.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

enum PreviewData {
    static let items: [WorkItem] = {
        let account = UUID()
        let now = Date()
        return [
            WorkItem(accountID: account, kind: .pullRequest, repoFullName: "dxheroes/mcp-gateway", number: 42,
                     title: "Add GitLab provider", url: URL(string: "https://github.com")!, author: UserRef(login: "prokopsimek"),
                     createdAt: now.addingTimeInterval(-86_400), updatedAt: now.addingTimeInterval(-600),
                     labels: [Label(name: "provider", colorHex: "0E8A16")], commentCount: 3,
                     reviewState: .approved, ciState: .success, mergeState: .clean, additions: 120, deletions: 7),
            WorkItem(accountID: account, kind: .pullRequest, repoFullName: "dxheroes/web", number: 17,
                     title: "Fix hero layout on narrow screens", url: URL(string: "https://github.com")!, author: UserRef(login: "alice"),
                     createdAt: now.addingTimeInterval(-3 * 86_400), updatedAt: now.addingTimeInterval(-5_400),
                     isDraft: true, reviewState: .pending, ciState: .failure, mergeState: .conflict),
            WorkItem(accountID: account, kind: .issue, repoFullName: "dxheroes/mcp-gateway", number: 7,
                     title: "Widget shows stale data after sleep", url: URL(string: "https://github.com")!, author: UserRef(login: "bob"),
                     createdAt: now.addingTimeInterval(-9 * 86_400), updatedAt: now.addingTimeInterval(-2 * 86_400),
                     labels: [Label(name: "bug", colorHex: "D73A4A")], commentCount: 1),
        ]
    }()
}

#Preview(as: .systemMedium) {
    GitwallWidget()
} timeline: {
    PresetEntry.placeholder
}

#Preview(as: .systemLarge) {
    GitwallWidget()
} timeline: {
    PresetEntry.placeholder
}
