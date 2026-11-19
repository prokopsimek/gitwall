import Foundation

/// The presets a regular sync fetches: the ones somebody can see right now or is waiting on. Everything else is
/// fetched when the user opens it. Each source keeps its own set so the log can say why the sync fetched what it did;
/// the popover and main window are one source and the Walls window another, because a wall left on a monitor keeps
/// its presets in every sync while a glance at the popover does not. A source counts presets, not widgets or tiles.
public struct SyncSelection: Equatable, Sendable {
    /// Every selected preset once, in the order of ``AppConfig/presets``.
    public let presetIDs: [UUID]
    /// Presets shown by the desktop widgets.
    public let widgets: Set<UUID>
    /// The preset whose count is next to the menu bar icon.
    public let menuBar: Set<UUID>
    /// Presets with at least one notification switched on.
    public let notifications: Set<UUID>
    /// Presets open in the popover or the main window.
    public let windows: Set<UUID>
    /// Presets of the tiles on the wall the Walls window shows.
    public let wall: Set<UUID>

    /// Only presets that exist are selected: an id from a window or a tile whose preset was deleted selects nothing.
    /// - Parameters:
    ///   - widgets: The preset each desktop widget is configured with, one entry per widget; nil when its
    ///     configuration names no preset.
    ///   - open: The presets open in the popover or the main window while they are visible.
    ///   - shownWall: The wall the Walls window shows, nil while the window is closed.
    public static func presets(in config: AppConfig, widgets: [UUID?], open: [UUID], shownWall: Wall.ID?) -> SyncSelection {
        let existing = Set(config.presets.map(\.id))
        // The widget's own fallback: a preset that is unset or no longer exists shows the first preset.
        let widgetPresets = Set(widgets.compactMap { id in
            id.flatMap { config.preset(id: $0) }?.id ?? config.presets.first?.id
        })
        // The badge counts the first preset that asks for it; any later one is never shown.
        let menuBar = Set([config.presets.first(where: \.showCountInMenuBar)?.id].compactMap(\.self))
        // A notification can only fire for an item the sync has seen change.
        let notifications = Set(config.presets.filter { !$0.notifications.isEmpty }.map(\.id))
        let windows = Set(open).intersection(existing)
        // Tiles stay on a wall when their preset is deleted.
        let wall = Set(shownWall.flatMap(config.wall(id:))?.tiles.map(\.presetID) ?? []).intersection(existing)
        let selected = widgetPresets.union(menuBar).union(notifications).union(windows).union(wall)
        return SyncSelection(
            presetIDs: config.presets.map(\.id).filter(selected.contains),
            widgets: widgetPresets,
            menuBar: menuBar,
            notifications: notifications,
            windows: windows,
            wall: wall
        )
    }
}
