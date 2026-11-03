import Foundation

/// What `FilterEngine` found for each saved preset, so a window that asks for many presets on every redraw does not
/// filter the snapshot again each time. The app empties it when the snapshot or what presets show changes.
///
/// One answer per preset id, replaced when the preset changes. A preset that differs from the saved one, as the
/// preset editor's unsaved copy does, is worked out every time and never stored. Answers expire with the minute, so
/// a filter by age keeps moving while nothing syncs (offline, or a failing account).
public struct FilterCache: Sendable {
    public static let lifetime: TimeInterval = 60

    private var minute: Int?
    private var entries: [UUID: Entry] = [:]

    private struct Entry: Sendable {
        let preset: Preset
        let items: [WorkItem]
    }

    public init() {}

    /// Answers stored now.
    public var count: Int { entries.count }

    /// - Parameters:
    ///   - saved: The preset with the same id as it is in the configuration, or nil.
    ///   - compute: Filters the snapshot; called only when there is no stored answer.
    public mutating func items(for preset: Preset, saved: Preset?, now: Date, compute: () -> [WorkItem]) -> [WorkItem] {
        guard preset == saved else { return compute() }
        let current = Int((now.timeIntervalSinceReferenceDate / Self.lifetime).rounded(.down))
        if current != minute {
            entries.removeAll()
            minute = current
        }
        if let entry = entries[preset.id], entry.preset == preset { return entry.items }
        let items = compute()
        entries[preset.id] = Entry(preset: preset, items: items)
        return items
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

extension AppConfig {
    /// Whether anything but the walls differs. Widgets and the filtered items depend on everything else; a change
    /// to the walls alone reloads neither.
    public func differsOutsideWalls(from other: AppConfig) -> Bool {
        var mine = self
        mine.walls = other.walls
        return mine != other
    }
}
