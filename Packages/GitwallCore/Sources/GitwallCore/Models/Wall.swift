import Foundation

/// How much room a tile takes on a wall: the four sizes of the desktop widgets, with as many rows as the widget of
/// that size shows.
public enum TileSize: String, Codable, CaseIterable, Hashable, Sendable {
    case small, medium, large, extraLarge

    /// Items a tile of this size lists, the same as the widget of this size.
    public var rowLimit: Int {
        switch self {
        case .small: 1
        case .medium: 3
        case .large: 7
        case .extraLarge: 14
        }
    }

    /// Width in grid cells. A cell is roughly a small widget, so the proportions match the desktop widgets.
    public var columns: Int {
        switch self {
        case .small: 1
        case .medium, .large: 2
        case .extraLarge: 4
        }
    }

    /// Height in grid cells.
    public var rows: Int {
        switch self {
        case .small, .medium: 1
        case .large, .extraLarge: 2
        }
    }

    /// 1 to 4, the keys that set a tile's size while editing a wall.
    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public init?(number: Int) {
        guard Self.allCases.indices.contains(number - 1) else { return nil }
        self = Self.allCases[number - 1]
    }
}

/// One preset shown on a wall at one size. The id only tells the tiles of one wall apart in this app; the
/// Gitwall file leaves it out.
public struct Tile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var presetID: UUID
    public var size: TileSize

    public init(id: UUID = UUID(), presetID: UUID, size: TileSize = .medium) {
        self.id = id
        self.presetID = presetID
        self.size = size
    }
}

/// A named arrangement of tiles, one tab of the Walls window. A tile points at a preset, so editing the preset
/// changes every wall that shows it, and deleting the preset leaves the tile in place until the user removes it.
public struct Wall: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var tiles: [Tile]

    public init(id: UUID = UUID(), name: String, tiles: [Tile] = []) {
        self.id = id
        self.name = name
        self.tiles = tiles
    }

    /// One medium tile per preset, in the presets' order: a first wall for someone who has none yet.
    public static func fromPresets(_ presets: [Preset], name: String) -> Wall {
        Wall(name: name, tiles: presets.map { Tile(presetID: $0.id) })
    }

    /// Same name and the same presets at the same sizes in the same order. Tile ids are local and do not count,
    /// so a wall pasted again over itself is unchanged.
    public func hasSameContent(as other: Wall) -> Bool {
        name == other.name && tiles.map(\.content) == other.tiles.map(\.content)
    }

    /// A new wall with new ids and the same tiles.
    public func duplicate() -> Wall {
        Wall(name: name + " copy", tiles: tiles.map { Tile(presetID: $0.presetID, size: $0.size) })
    }

    // MARK: Editing

    @discardableResult
    public mutating func addTile(presetID: UUID, size: TileSize = .medium) -> Tile.ID {
        let tile = Tile(presetID: presetID, size: size)
        tiles.append(tile)
        return tile.id
    }

    public mutating func removeTile(_ id: Tile.ID) {
        tiles.removeAll { $0.id == id }
    }

    public mutating func setSize(_ size: TileSize, ofTile id: Tile.ID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[index].size = size
    }

    /// Moves a tile in front of `target`, or to the end when `target` is nil, as a drop on a tile does.
    public mutating func moveTile(_ id: Tile.ID, before target: Tile.ID?) {
        guard id != target, let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles.remove(at: index)
        let destination = target.flatMap { target in tiles.firstIndex { $0.id == target } } ?? tiles.endIndex
        tiles.insert(tile, at: destination)
    }
}

private extension Tile {
    struct Content: Hashable {
        let presetID: UUID
        let size: TileSize
    }

    var content: Content { Content(presetID: presetID, size: size) }
}

/// One wall added, changed or removed. Undo applies the inverse, which finds the wall by its id, so walls that
/// arrived in between (a paste) stay where they are.
public struct WallChange: Equatable, Sendable {
    public var before: Wall?
    public var after: Wall?
    /// Where the wall is, or where it goes back when an undo brings it back.
    public var index: Int

    public init(before: Wall?, after: Wall?, index: Int) {
        self.before = before
        self.after = after
        self.index = index
    }

    public var inverse: WallChange {
        WallChange(before: after, after: before, index: index)
    }

    public func apply(to walls: [Wall]) -> [Wall] {
        var result = walls
        let id = (after ?? before)?.id
        if let existing = result.firstIndex(where: { $0.id == id }) {
            if let after {
                result[existing] = after
            } else {
                result.remove(at: existing)
            }
        } else if let after {
            result.insert(after, at: min(max(index, 0), result.count))
        }
        return result
    }
}

/// Moving around the Walls window with the keyboard.
public enum WallNavigation {
    /// The next (`offset` 1) or previous (-1) wall, wrapping around. Without a current wall, the first one.
    public static func wall(after id: Wall.ID?, offset: Int, in walls: [Wall]) -> Wall.ID? {
        guard let index = walls.firstIndex(where: { $0.id == id }) else { return walls.first?.id }
        return walls[wrapped(index + offset, count: walls.count)].id
    }

    /// Tab and Shift-Tab: the next or previous tile, wrapping around. Without a current tile, the first or the last.
    public static func tile(after id: Tile.ID?, offset: Int, in wall: Wall) -> Tile.ID? {
        guard !wall.tiles.isEmpty else { return nil }
        guard let index = wall.tiles.firstIndex(where: { $0.id == id }) else {
            return offset < 0 ? wall.tiles.last?.id : wall.tiles.first?.id
        }
        return wall.tiles[wrapped(index + offset, count: wall.tiles.count)].id
    }

    /// Up and down arrows inside one tile; they stop at the first and the last item. Without a current item, down
    /// starts at the first and up at the last.
    public static func item(after id: String?, offset: Int, in items: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        guard let id, let index = items.firstIndex(of: id) else {
            return offset < 0 && id == nil ? items.last : items.first
        }
        return items[min(max(index + offset, 0), items.count - 1)]
    }

    /// Which wall to show after `change`, given the walls after it and the selected one: an added or changed wall
    /// is shown; when the shown wall is removed, the one now in its place, or the one before it at the end.
    public static func selection(after change: WallChange, in walls: [Wall], selected: Wall.ID?) -> WallSelectionChange {
        let shown = walls.first { $0.id == selected } ?? walls.first
        if let after = change.after {
            return after.id == shown?.id ? .keep : .select(after.id)
        }
        guard selected == change.before?.id || shown == nil else { return .keep }
        return .select(walls.isEmpty ? nil : walls[min(max(change.index, 0), walls.count - 1)].id)
    }

    private static func wrapped(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}

/// What ``WallNavigation/selection(after:in:selected:)`` decides.
public enum WallSelectionChange: Equatable, Sendable {
    case keep
    /// Show this wall, with nothing selected on it; nil when no wall is left.
    case select(Wall.ID?)
}

/// Switching walls by themselves, for a wall on a monitor nobody touches. Off by default.
public struct WallRotation: Equatable, Sendable {
    /// The choices in View › Rotation Interval, in seconds.
    public static let intervals: [TimeInterval] = [30, 60, 120, 300]
    public static let defaultInterval: TimeInterval = 60
    /// Someone using the window with the keyboard or the mouse holds the rotation this long.
    public static let pauseAfterInput: TimeInterval = 120

    public var interval: TimeInterval

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// The stored choice, or the default when there is none or it is not one of ``intervals``.
    public init(storedInterval: TimeInterval?) {
        self.init(interval: storedInterval.flatMap { Self.intervals.contains($0) ? $0 : nil } ?? Self.defaultInterval)
    }

    /// When the next wall is due: one interval after the last switch, and never sooner than two quiet minutes
    /// after the last input.
    public func nextAdvance(lastAdvance: Date, lastInput: Date?) -> Date {
        let due = lastAdvance.addingTimeInterval(interval)
        guard let lastInput else { return due }
        return max(due, lastInput.addingTimeInterval(Self.pauseAfterInput))
    }
}
