import GitwallCore

/// What `FilterEngine` found for a preset in the current snapshot. A wall asks for many presets on every redraw, and
/// counts in the sidebar, popover and settings ask again, so each answer is kept until the snapshot or the
/// configuration changes (`AppEnvironment` empties it then).
///
/// Keyed by the whole preset, not its id: the preset editor asks for its unsaved copy. A filter by age
/// (`updatedWithinDays`) is evaluated when the answer is first needed and stays until the next sync replaces the
/// snapshot, as in the widgets.
@MainActor
final class ItemsCache {
    private var items: [Preset: [WorkItem]] = [:]

    func items(for preset: Preset, compute: () -> [WorkItem]) -> [WorkItem] {
        if let cached = items[preset] { return cached }
        let computed = compute()
        items[preset] = computed
        return computed
    }

    func removeAll() {
        items.removeAll()
    }
}
