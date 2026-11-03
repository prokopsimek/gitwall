import Foundation
import Testing
@testable import GitwallCore

@Suite("Walls")
struct WallTests {
    let reviewID = UUID(uuidString: "6F0C2D6A-1B7E-4C55-9E0A-2D8E4B1F7A10")!
    let bugsID = UUID(uuidString: "0B5E9C3E-77A2-4F1D-8C64-5A9D2E7F3B21")!

    // MARK: - Tile sizes

    @Test("tile sizes show as many rows as the widget of that size, and take its share of the grid")
    func sizes() {
        #expect(TileSize.allCases == [.small, .medium, .large, .extraLarge])
        #expect(TileSize.allCases.map(\.rowLimit) == [1, 3, 7, 14])
        #expect(TileSize.allCases.map(\.columns) == [1, 2, 2, 4])
        #expect(TileSize.allCases.map(\.rows) == [1, 1, 2, 2])
    }

    @Test("the keys 1 to 4 name the sizes from small to extra large")
    func numbers() {
        #expect((1...4).compactMap(TileSize.init(number:)) == TileSize.allCases)
        #expect(TileSize(number: 0) == nil)
        #expect(TileSize(number: 5) == nil)
        #expect(TileSize.allCases.map(\.number) == [1, 2, 3, 4])
    }

    // MARK: - Walls

    @Test("a wall made from presets has one medium tile per preset, in their order")
    func fromPresets() {
        let presets = [Preset(id: reviewID, name: "Review"), Preset(id: bugsID, name: "Bugs")]
        let wall = Wall.fromPresets(presets, name: "All presets")
        #expect(wall.name == "All presets")
        #expect(wall.tiles.map(\.presetID) == [reviewID, bugsID])
        #expect(wall.tiles.allSatisfy { $0.size == .medium })
        #expect(Set(wall.tiles.map(\.id)).count == 2)
    }

    @Test("two walls have the same content when only their tile ids differ")
    func sameContent() {
        let wall = Wall(name: "Mine", tiles: [Tile(presetID: reviewID, size: .large), Tile(presetID: bugsID)])
        var other = wall
        other.tiles = wall.tiles.map { Tile(presetID: $0.presetID, size: $0.size) }
        #expect(other != wall)
        #expect(other.hasSameContent(as: wall))

        var renamed = wall
        renamed.name = "Theirs"
        #expect(!renamed.hasSameContent(as: wall))
        var resized = wall
        resized.tiles[1].size = .small
        #expect(!resized.hasSameContent(as: wall))
        var reordered = wall
        reordered.tiles.reverse()
        #expect(!reordered.hasSameContent(as: wall))
    }

    @Test("a duplicate is a new wall with new tile ids and the same tiles")
    func duplicate() {
        let wall = Wall(name: "Mine", tiles: [Tile(presetID: reviewID, size: .large)])
        let copy = wall.duplicate()
        #expect(copy.id != wall.id)
        #expect(copy.name == "Mine copy")
        #expect(copy.tiles.map(\.id) != wall.tiles.map(\.id))
        #expect(copy.tiles.map(\.presetID) == [reviewID])
        #expect(copy.tiles.map(\.size) == [.large])
    }

    // MARK: - config.json

    @Test("a config.json written before walls existed loads with no walls")
    func oldConfigLoads() throws {
        let config = try SnapshotCoding.decode(AppConfig.self, from: Fixtures.data("config.json"))
        #expect(config.walls.isEmpty)
        #expect(config.presets.count == 2)
    }

    @Test("walls survive a round trip through config.json")
    func configRoundTrip() throws {
        var config = AppConfig(presets: [Preset(id: reviewID, name: "Review")])
        config.walls = [Wall(name: "Desk", tiles: [Tile(presetID: reviewID, size: .extraLarge), Tile(presetID: bugsID, size: .small)])]
        let data = try SnapshotCoding.encode(config)
        #expect(try SnapshotCoding.decode(AppConfig.self, from: data) == config)
        #expect(config.wall(id: config.walls[0].id) == config.walls[0])
    }

    // MARK: - Editing

    @Test("adding, resizing, moving and removing tiles")
    func editing() throws {
        var wall = Wall(name: "Desk")
        let first = wall.addTile(presetID: reviewID)
        let second = wall.addTile(presetID: bugsID, size: .large)
        let third = wall.addTile(presetID: reviewID, size: .small)
        #expect(wall.tiles.map(\.id) == [first, second, third])
        #expect(wall.tiles[0].size == .medium)

        wall.setSize(.extraLarge, ofTile: first)
        #expect(wall.tiles[0].size == .extraLarge)

        wall.moveTile(first, before: third)
        #expect(wall.tiles.map(\.id) == [second, first, third])
        wall.moveTile(second, before: nil)
        #expect(wall.tiles.map(\.id) == [first, third, second])
        wall.moveTile(second, before: first)
        #expect(wall.tiles.map(\.id) == [second, first, third])
        wall.moveTile(first, before: first)
        #expect(wall.tiles.map(\.id) == [second, first, third])

        wall.removeTile(first)
        #expect(wall.tiles.map(\.id) == [second, third])
        wall.removeTile(UUID())
        #expect(wall.tiles.map(\.id) == [second, third])
    }

    @Test("a change is undone by its inverse, by id, even after other walls moved")
    func changes() {
        let a = Wall(name: "A")
        let b = Wall(name: "B")
        var renamedB = b
        renamedB.name = "B2"
        let c = Wall(name: "C")
        let start = [a, b]

        let added = WallChange(before: nil, after: c, index: 1)
        #expect(added.apply(to: start).map(\.name) == ["A", "C", "B"])
        #expect(added.inverse.apply(to: added.apply(to: start)) == start)

        let renamed = WallChange(before: b, after: renamedB, index: 1)
        #expect(renamed.apply(to: start).map(\.name) == ["A", "B2"])
        // Another wall appended in between (a paste) does not get in the way.
        let pasted = renamed.apply(to: start) + [c]
        #expect(renamed.inverse.apply(to: pasted).map(\.name) == ["A", "B", "C"])

        let deleted = WallChange(before: a, after: nil, index: 0)
        #expect(deleted.apply(to: start).map(\.name) == ["B"])
        #expect(deleted.inverse.apply(to: deleted.apply(to: start)) == start)
        // Inserting goes no further than the end.
        #expect(WallChange(before: nil, after: c, index: 9).apply(to: start).map(\.name) == ["A", "B", "C"])
    }

    // MARK: - Navigation

    @Test("next and previous wall wrap around")
    func wallNavigation() {
        let walls = [Wall(name: "A"), Wall(name: "B"), Wall(name: "C")]
        let ids = walls.map(\.id)
        #expect(WallNavigation.wall(after: ids[0], offset: 1, in: walls) == ids[1])
        #expect(WallNavigation.wall(after: ids[2], offset: 1, in: walls) == ids[0])
        #expect(WallNavigation.wall(after: ids[0], offset: -1, in: walls) == ids[2])
        #expect(WallNavigation.wall(after: nil, offset: 1, in: walls) == ids[0])
        #expect(WallNavigation.wall(after: UUID(), offset: -1, in: walls) == ids[0])
        #expect(WallNavigation.wall(after: nil, offset: 1, in: []) == nil)
    }

    @Test("tab moves between tiles and wraps around")
    func tileNavigation() {
        var wall = Wall(name: "Desk")
        let first = wall.addTile(presetID: reviewID)
        let second = wall.addTile(presetID: bugsID)
        #expect(WallNavigation.tile(after: first, offset: 1, in: wall) == second)
        #expect(WallNavigation.tile(after: second, offset: 1, in: wall) == first)
        #expect(WallNavigation.tile(after: first, offset: -1, in: wall) == second)
        #expect(WallNavigation.tile(after: nil, offset: 1, in: wall) == first)
        #expect(WallNavigation.tile(after: nil, offset: -1, in: wall) == second)
        #expect(WallNavigation.tile(after: nil, offset: 1, in: Wall(name: "Empty")) == nil)
    }

    @Test("arrows move through the items of one tile and stop at its ends")
    func itemNavigation() {
        let items = ["a", "b", "c"]
        #expect(WallNavigation.item(after: "a", offset: 1, in: items) == "b")
        #expect(WallNavigation.item(after: "c", offset: 1, in: items) == "c")
        #expect(WallNavigation.item(after: "a", offset: -1, in: items) == "a")
        #expect(WallNavigation.item(after: nil, offset: 1, in: items) == "a")
        #expect(WallNavigation.item(after: nil, offset: -1, in: items) == "c")
        #expect(WallNavigation.item(after: "gone", offset: 1, in: items) == "a")
        #expect(WallNavigation.item(after: nil, offset: 1, in: []) == nil)
    }

    // MARK: - Rotation

    @Test("rotation waits for the interval and for two quiet minutes after any input")
    func rotation() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rotation = WallRotation(interval: 60)
        #expect(rotation.nextAdvance(lastAdvance: start, lastInput: nil) == start.addingTimeInterval(60))
        #expect(rotation.nextAdvance(lastAdvance: start, lastInput: start.addingTimeInterval(-500)) == start.addingTimeInterval(60))
        #expect(rotation.nextAdvance(lastAdvance: start, lastInput: start.addingTimeInterval(30)) == start.addingTimeInterval(150))
    }

    @Test("only the offered intervals are used; anything else falls back to one minute")
    func rotationIntervals() {
        #expect(WallRotation.intervals == [30, 60, 120, 300])
        #expect(WallRotation(storedInterval: 120).interval == 120)
        #expect(WallRotation(storedInterval: 7).interval == 60)
        #expect(WallRotation(storedInterval: nil).interval == 60)
    }
}
