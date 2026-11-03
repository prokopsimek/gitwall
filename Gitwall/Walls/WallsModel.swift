import AppKit
import GitwallCore
import GitwallUI
import Observation

/// State of the Walls window and everything its menus and keys do. Walls live in `AppConfig.walls`; every edit goes
/// through ``apply(_:actionName:)``, which registers the undo. The decisions (layout, navigation, rotation timing)
/// are GitwallCore's; this only keeps the window's selection and preferences. The selection drives the window's
/// ``detail``: Detail shows the selected item, ↑↓ move it, and the selected tile's rows are Detail's list.
@MainActor
@Observable
final class WallsModel {
    let environment: AppEnvironment
    /// Detail next to the wall, following ``selectedItemID``.
    let detail: DetailModel
    /// The window's own undo manager, which Edit › Undo and ⌘Z reach (`WallsWindowController` hands it over).
    @ObservationIgnored var undoManager: UndoManager?
    /// What clicking a row does with an item: shows it in Detail. Space and Return reach Detail through the Item
    /// menu's Show Detail; ⌘↩ and a double click open the browser.
    @ObservationIgnored var onActivate: (WorkItem) -> Void = { _ in }
    @ObservationIgnored private let defaults: UserDefaults

    var selectedWallID: UUID? {
        didSet { defaults.set(selectedWallID?.uuidString, forKey: Keys.lastWall) }
    }
    var selectedTileID: UUID? {
        didSet { if selectedTileID != oldValue { syncDetail() } }
    }
    var selectedItemID: String? {
        didSet { if selectedItemID != oldValue { syncDetail() } }
    }
    var isEditing = false
    /// The tab whose name is being typed (``beginRename(_:)``), and what is typed so far.
    private(set) var renamingWallID: UUID?
    var renameDraft = ""
    /// The window's zoom (⌘+, ⌘−, ⌘0).
    var zoom: Double {
        didSet { defaults.set(zoom, forKey: Keys.zoom) }
    }
    /// Full screen, the wall fills the screen (`WallLayout.fit`), and ⌘+ and ⌘− zoom relative to that fit, apart from
    /// the window's zoom. The window controller sets it as the window enters and leaves full screen.
    var isFullScreen = false
    var fullScreenZoom: Double {
        didSet { defaults.set(fullScreenZoom, forKey: Keys.fullScreenZoom) }
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
        static let fullScreenZoom = "GitwallWalls.fullScreenZoom"
        static let rotates = "GitwallWalls.rotates"
        static let rotationInterval = "GitwallWalls.rotationInterval"
    }

    init(environment: AppEnvironment, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.defaults = defaults
        detail = DetailModel(environment: environment)
        selectedWallID = defaults.string(forKey: Keys.lastWall).flatMap(UUID.init(uuidString:))
        zoom = defaults.object(forKey: Keys.zoom) as? Double ?? 1
        fullScreenZoom = defaults.object(forKey: Keys.fullScreenZoom) as? Double ?? 1
        rotates = defaults.bool(forKey: Keys.rotates)
        rotation = WallRotation(storedInterval: defaults.object(forKey: Keys.rotationInterval) as? Double)
        // Undoing an edit of a wall a paste has replaced would write the old content over the pasted one.
        environment.onWallsReplacedByPaste = { [weak self] in self?.undoManager?.removeAllActions() }
        onActivate = { [weak self] item in self?.detail.show(item.id) }
    }

    /// Detail shows the selected item, never one of another tile, and ↑↓ go through the selected tile's rows.
    private func syncDetail() {
        detail.visibleItemIDs = selectedTile.map { visibleItems(for: $0).map(\.id) } ?? []
        detail.select(selectedItemID)
    }

    /// The preset of the tile that holds the selection, which "Why it's here" explains the item by.
    var detailPreset: Preset? {
        selectedTile.flatMap(preset(for:))
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

    /// What `WallsCommand.isEnabled` needs. The window says whether it is the key window and whether a text field
    /// has the keyboard.
    func state(isKeyWindow: Bool, isTyping: Bool) -> WallsState {
        WallsState(
            isKeyWindow: isKeyWindow,
            isTyping: isTyping || renamingWallID != nil,
            hasContent: environment.containerAvailable && !environment.needsOnboarding,
            wallCount: walls.count,
            tileCount: currentWall?.tiles.count ?? 0,
            hasSelectedTile: selectedTile != nil,
            hasSelectedItem: selectedItem != nil,
            isEditing: isEditing,
            presetCount: environment.config.presets.count,
            zoom: isFullScreen ? fullScreenZoom : zoom,
            isDetailPresented: detail.isPresented
        )
    }

    // MARK: Moving around

    /// A name being typed is kept before the other wall comes up.
    func selectWall(_ id: Wall.ID) {
        guard id != currentWall?.id else { return }
        commitRename()
        selectedWallID = id
        selectedTileID = nil
        selectedItemID = nil
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

    // MARK: Zoom

    /// ⌘+ and ⌘− (`step` 1 and -1) and ⌘0 (0): the window's zoom, or full screen the zoom relative to the fit, which
    /// ⌘0 returns to.
    func zoom(step: Int) {
        let current = isFullScreen ? fullScreenZoom : zoom
        let next = step == 0 ? 1 : WallLayout.zoom(current, step: step)
        if isFullScreen { fullScreenZoom = next } else { zoom = next }
    }

    // MARK: Editing walls

    func newWall() {
        let wall = Wall(name: "New Wall")
        apply(WallChange(before: nil, after: wall, index: walls.count), actionName: "New Wall")
        beginRename(wall.id)
    }

    /// One medium tile per preset, in their order.
    func newWallFromPresets() {
        let wall = Wall.fromPresets(environment.config.presets, name: "All Presets")
        apply(WallChange(before: nil, after: wall, index: walls.count), actionName: "New Wall from Presets")
    }

    /// Starts typing a name for `id`, or for the wall on screen.
    func beginRename(_ id: Wall.ID? = nil) {
        let target = id ?? currentWall?.id
        guard let wall = walls.first(where: { $0.id == target }) else { return }
        renamingWallID = wall.id
        renameDraft = wall.name
    }

    /// Writes the name being typed; an empty one keeps the old name.
    func commitRename() {
        guard let id = renamingWallID else { return }
        rename(id, to: renameDraft)
    }

    func cancelRename() {
        renamingWallID = nil
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
        if case .select(let id) = WallNavigation.selection(after: change, in: walls, selected: selectedWallID) {
            selectedWallID = id
            selectedTileID = nil
            selectedItemID = nil
        }
    }
}
