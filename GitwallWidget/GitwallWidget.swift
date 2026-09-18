import GitwallCore
import GitwallUI
import OSLog
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "widget")

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

        // App Review could not see what a widget does without connecting an account first (guideline 2.1(a)),
        // and neither can anyone else trying Gitwall out. Sample rows say what they are and link to the accounts
        // tab, so the prompt to connect is still there.
        guard !config.accounts.isEmpty else {
            // Edit Widget offers the sample presets here (`PresetQuery`), so honour the one picked.
            let preset = presetID.flatMap { id in DemoData.presets.first { $0.id == id } } ?? DemoData.presets.first
            let items = preset.map { FilterEngine.items(matching: $0, in: DemoData.snapshot().items, accounts: DemoData.config.accounts, now: now) } ?? []
            return PresetEntry(date: now, preset: preset, items: items, fetchedAt: now, staleAfter: staleAfter, container: container, problem: preset == nil ? .noAccounts : nil, attention: false, isDefaultPreset: true, presetCount: config.presets.count, isSample: preset != nil)
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
