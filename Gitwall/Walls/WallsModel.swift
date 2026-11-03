import AppKit
import GitwallCore
import GitwallUI
import Observation

/// State of the Walls window and everything its menus and keys do. Walls live in `AppConfig.walls`; every edit goes
/// through ``apply(_:actionName:)``, which registers the undo. The decisions (layout, navigation, rotation timing)
/// are GitwallCore's; this only keeps the window's selection and preferences.
@MainActor
@Observable
final class WallsModel {
    let environment: AppEnvironment
    /// The window's own undo manager, which Edit › Undo and ⌘Z reach (`WallsWindowController` hands it over).
    @ObservationIgnored var undoManager: UndoManager?
    /// What clicking a row, Return and Space do with an item. The one place that decides it: today it opens the
    /// item in the browser (`WallsWindowController` sets it).
    @ObservationIgnored var onActivate: (WorkItem) -> Void = { _ in }
    @ObservationIgnored private let defaults: UserDefaults

    var selectedWallID: UUID? {
        didSet { defaults.set(selectedWallID?.uuidString, forKey: Keys.lastWall) }
    }
    var selectedTileID: UUID?
    var selectedItemID: String?
    var isEditing = false
    /// The tab whose name is being typed.
    var renamingWallID: UUID?
    var zoom: Double {
        didSet { defaults.set(zoom, forKey: Keys.zoom) }
    }
    var rotates: Bool {
        didSet { defaults.set(rotates, forKey: Keys.rotates) }
    }
    var rotation: WallRotation {
        didSet { defaults.set(rotation.interval, forKey: Keys.rotationInterval) }
    }

    private enum Keys {
        static let lastWall = "GitwallWalls.lastWall"
        static let zoom = "GitwallWalls.zoom"
        static let rotates = "GitwallWalls.rotates"
        static let rotationInterval = "GitwallWalls.rotationInterval"
    }

    init(environment: AppEnvironment, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.defaults = defaults
        selectedWallID = defaults.string(forKey: Keys.lastWall).flatMap(UUID.init(uuidString:))
        zoom = defaults.object(forKey: Keys.zoom) as? Double ?? 1
        rotates = defaults.bool(forKey: Keys.rotates)
        rotation = WallRotation(storedInterval: defaults.object(forKey: Keys.rotationInterval) as? Double)
    }

    // MARK: What is on screen

    var walls: [Wall] { environment.config.walls }

    /// The selected wall, or the first one when the remembered one is gone.
    var currentWall: Wall? {
        walls.first { $0.id == selectedWallID } ?? walls.first
    }

    func preset(for tile: Tile) -> Preset? {
        environment.config.preset(id: tile.presetID)
    }

    func items(for tile: Tile) -> [WorkItem] {
        preset(for: tile).map { environment.items(for: $0) } ?? []
    }

    /// The rows a tile lists, in the order the arrow keys go through them.
    func visibleItems(for tile: Tile) -> [WorkItem] {
        TileRows(items: items(for: tile), size: tile.size).visible
    }

    var selectedTile: Tile? {
        currentWall?.tiles.first { $0.id == selectedTileID }
    }

    var selectedItem: WorkItem? {
        guard let tile = selectedTile else { return nil }
        return visibleItems(for: tile).first { $0.id == selectedItemID }
    }

    // MARK: Moving around

    func selectWall(_ id: Wall.ID) {
        guard id != currentWall?.id else { return }
        selectedWallID = id
        selectedTileID = nil
        selectedItemID = nil
        renamingWallID = nil
    }

    /// Next (1) or previous (-1) wall, wrapping around.
    func showWall(offset: Int) {
        if let id = WallNavigation.wall(after: currentWall?.id, offset: offset, in: walls) { selectWall(id) }
    }

    /// Tab and Shift-Tab.
    func selectTile(offset: Int) {
        guard let wall = currentWall else { return }
        selectedTileID = WallNavigation.tile(after: selectedTile?.id, offset: offset, in: wall)
        selectedItemID = nil
    }

    /// Up and down inside the selected tile; the first tile when none is selected yet.
    func selectItem(offset: Int) {
        if selectedTile == nil { selectTile(offset: 1) }
        guard let tile = selectedTile else { return }
        selectedItemID = WallNavigation.item(after: selectedItem?.id, offset: offset, in: visibleItems(for: tile).map(\.id))
    }

    func select(_ item: WorkItem, in tile: Tile) {
        selectedTileID = tile.id
        selectedItemID = item.id
    }

    func selectTile(_ tile: Tile) {
        guard selectedTileID != tile.id else { return }
        selectedTileID = tile.id
        selectedItemID = nil
    }

    func activate(_ item: WorkItem) {
        onActivate(item)
    }

    func activateSelection() {
        if let item = selectedItem { activate(item) }
    }

    func openSelectionInBrowser() {
        if let item = selectedItem { environment.open(item) }
    }

    // MARK: Zoom

    func zoom(step: Int) {
        zoom = step == 0 ? 1 : WallLayout.zoom(zoom, step: step)
    }

    // MARK: Editing walls

    func newWall() {
        let wall = Wall(name: "New Wall")
        apply(WallChange(before: nil, after: wall, index: walls.count), actionName: "New Wall")
        renamingWallID = wall.id
    }

    /// One medium tile per preset, in their order.
    func newWallFromPresets() {
        let wall = Wall.fromPresets(environment.config.presets, name: "All Presets")
        apply(WallChange(before: nil, after: wall, index: walls.count), actionName: "New Wall from Presets")
    }

    func rename(_ id: Wall.ID, to name: String) {
        renamingWallID = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id, actionName: "Rename Wall") { $0.name = trimmed }
    }

    func duplicate(_ id: Wall.ID) {
        guard let index = walls.firstIndex(where: { $0.id == id }) else { return }
        apply(WallChange(before: nil, after: walls[index].duplicate(), index: index + 1), actionName: "Duplicate Wall")
    }

    func delete(_ id: Wall.ID) {
        guard let index = walls.firstIndex(where: { $0.id == id }) else { return }
        apply(WallChange(before: walls[index], after: nil, index: index), actionName: "Delete Wall")
    }

    func addTile(presetID: UUID) {
        guard let wall = currentWall else { return }
        var added: Tile.ID?
        update(wall.id, actionName: "Add Tile") { added = $0.addTile(presetID: presetID) }
        selectedTileID = added
    }

    func removeTile(_ id: Tile.ID) {
        guard let wall = currentWall else { return }
        update(wall.id, actionName: "Remove Tile") { $0.removeTile(id) }
        if selectedTileID == id { selectedTileID = nil }
    }

    func setSize(_ size: TileSize, ofTile id: Tile.ID) {
        guard let wall = currentWall else { return }
        update(wall.id, actionName: "Change Tile Size") { $0.setSize(size, ofTile: id) }
    }

    func moveTile(_ id: Tile.ID, before target: Tile.ID?) {
        guard let wall = currentWall else { return }
        update(wall.id, actionName: "Move Tile") { $0.moveTile(id, before: target) }
    }

    private func update(_ id: Wall.ID, actionName: String, _ change: (inout Wall) -> Void) {
        guard let index = walls.firstIndex(where: { $0.id == id }) else { return }
        var after = walls[index]
        change(&after)
        guard after != walls[index] else { return }
        apply(WallChange(before: walls[index], after: after, index: index), actionName: actionName)
    }

    /// Writes one change and registers its inverse with the window's undo manager; undoing registers the redo.
    private func apply(_ change: WallChange, actionName: String) {
        environment.setWalls(change.apply(to: walls))
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.apply(change.inverse, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        if let after = change.after {
            if after.id != currentWall?.id { selectWall(after.id) }
        } else if selectedWallID == change.before?.id || currentWall == nil {
            selectedWallID = walls.isEmpty ? nil : walls[min(change.index, walls.count - 1)].id
            selectedTileID = nil
            selectedItemID = nil
        }
    }
}
