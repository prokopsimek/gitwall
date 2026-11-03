import Foundation
import GitwallAuth
import GitwallCore
import GitwallUI
@testable import Gitwall
import Testing

/// Detail next to a wall: the wall's selection drives it, and the tile that holds the item explains it.
@Suite("Walls · Detail")
@MainActor
struct WallsDetailTests {
    /// Sample data, so the walls have tiles with items and nothing touches the network or the App Group.
    private func model() -> WallsModel {
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: InMemoryTokenStore(),
            sandbox: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gitwall-walls-detail-\(UUID().uuidString)")
        )
        environment.start()
        environment.enterSampleData()
        return WallsModel(environment: environment, defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!)
    }

    @Test("↑↓ in a tile move Detail's selection, and Detail's list is the tile's rows")
    func arrowsMoveDetail() throws {
        let model = model()
        model.selectItem(offset: 1)
        let tile = try #require(model.selectedTile)
        let rows = model.visibleItems(for: tile).map(\.id)
        #expect(rows.count > 1)

        #expect(model.detail.selectedItemID == rows[0])
        #expect(model.detail.visibleItemIDs == rows)
        model.selectItem(offset: 1)
        #expect(model.detail.selectedItemID == rows[1])
        #expect(!model.detail.isPresented, "moving alone does not open Detail")
    }

    @Test("a click, Space and Return show Detail of the item")
    func activateShowsDetail() throws {
        let model = model()
        let tile = try #require(model.currentWall?.tiles.first { !model.visibleItems(for: $0).isEmpty })
        let item = try #require(model.visibleItems(for: tile).last)

        model.select(item, in: tile)
        model.activate(item)

        #expect(model.detail.isPresented)
        #expect(model.detail.selectedItemID == item.id)
        #expect(model.state(isKeyWindow: true, isTyping: false).isDetailPresented)
    }

    @Test("another tile or wall takes Detail's selection with it")
    func selectionFollowsTheWall() throws {
        let model = model()
        model.selectItem(offset: 1)
        #expect(model.detail.selectedItemID != nil)

        model.selectTile(offset: 1)
        #expect(model.detail.selectedItemID == nil)
        let tile = try #require(model.selectedTile)
        #expect(model.detail.visibleItemIDs == model.visibleItems(for: tile).map(\.id))

        model.selectItem(offset: 1)
        let other = try #require(model.walls.first { $0.id != model.currentWall?.id })
        model.selectWall(other.id)
        #expect(model.detail.selectedItemID == nil)
        #expect(model.detail.visibleItemIDs.isEmpty)
    }

    @Test("Tab, a click on a tile and another wall leave nothing selected and close Detail; ↑↓ keep it open")
    func navigationClosesDetail() throws {
        let model = model()
        model.selectItem(offset: 1)
        model.detail.present()
        model.selectItem(offset: 1)
        #expect(model.detail.isPresented, "Detail follows the arrows")

        model.selectTile(offset: 1)
        #expect(!model.detail.isPresented)

        model.selectItem(offset: 1)
        model.detail.present()
        let other = try #require(model.currentWall?.tiles.first { $0.id != model.selectedTileID })
        model.selectTile(other)
        #expect(!model.detail.isPresented)

        model.selectItem(offset: 1)
        model.detail.present()
        model.showWall(offset: 1)
        #expect(!model.detail.isPresented, "⌃⇥, ⇧⌘] and rotation all switch walls this way")
        #expect(model.detail.selectedItemID == nil)
    }

    @Test("Detail opened on an empty wall closes when another wall comes up")
    func emptyDetailClosesOnAnotherWall() throws {
        let model = model()
        model.environment.setWalls(model.walls + [Wall(name: "Empty")])
        model.selectWall(try #require(model.walls.last).id)
        model.detail.present()
        #expect(model.detail.isPresented)
        #expect(model.detail.selectedItemID == nil)

        model.showWall(offset: 1)
        #expect(!model.detail.isPresented)
    }

    @Test("Why it's here explains the item by the preset of the tile that holds it")
    func explainedByTheTile() throws {
        let model = model()
        model.selectItem(offset: 1)
        let tile = try #require(model.selectedTile)
        let preset = try #require(model.preset(for: tile))
        let item = try #require(model.selectedItem)

        #expect(model.detailPreset == preset)
        #expect(model.detail.content(for: item, preset: model.detailPreset).presetName == preset.name)
    }
}
