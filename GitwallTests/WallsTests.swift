import AppKit
import Foundation
import GitwallAuth
import GitwallCore
@testable import Gitwall
import Testing

/// Walls in the app: what the environment writes and caches. The rules of the file and the layout are tested in
/// GitwallCore (`GitwallFileTests`, `WallLayoutTests`); this checks that the app carries them out.
@Suite("Walls in the app")
@MainActor
struct WallsAppTests {
    private func environment() -> AppEnvironment {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitwall-walls-\(UUID().uuidString)")
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: InMemoryTokenStore(),
            sandbox: sandbox
        )
        environment.start()
        return environment
    }

    private func model(_ environment: AppEnvironment) -> WallsModel {
        WallsModel(environment: environment, defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!)
    }

    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("gitwall.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    @Test("walls are written to config.json")
    func wallsPersist() throws {
        let environment = environment()
        let preset = Preset(name: "Mine")
        environment.addPreset(preset)
        let wall = Wall.fromPresets([preset], name: "Desk")

        environment.setWalls([wall])

        #expect(environment.config.walls == [wall])
        #expect(try environment.configStore?.load().walls == [wall])
    }

    @Test("walls edited while showing sample data stay in memory")
    func sampleWallsStayInMemory() throws {
        let environment = environment()
        environment.enterSampleData()
        #expect(!environment.config.walls.isEmpty)

        environment.setWalls([])

        #expect(environment.config.walls.isEmpty)
        #expect(try environment.configStore?.load() == .empty)
    }

    @Test("pasting a file writes its presets and walls; nothing already there is removed")
    func pasteConfiguration() throws {
        let environment = environment()
        let kept = Preset(name: "Kept")
        environment.addPreset(kept)
        let keptWall = Wall(name: "Kept wall", tiles: [Tile(presetID: kept.id)])
        environment.setWalls([keptWall])
        let pasted = Preset(name: "Pasted", filter: ItemFilter(query: "label:bug"))
        let file = GitwallFile(presets: [pasted], walls: [Wall(name: "Bugs", tiles: [Tile(presetID: pasted.id, size: .large)])])

        #expect(environment.pastePreview(file).summary == "1 new wall, 1 new preset")
        environment.pasteConfiguration(file)

        let stored = try #require(try environment.configStore?.load())
        #expect(stored.presets.map(\.id).suffix(2) == [kept.id, pasted.id])
        #expect(stored.walls.map(\.name) == ["Kept wall", "Bugs"])
        #expect(stored.walls[0] == keptWall)
    }

    @Test("Copy Wall as JSON pastes back without a change, with the presets it needs")
    func copyWallThenPaste() throws {
        let environment = environment()
        let preset = Preset(name: "Agents", filter: ItemFilter(query: "involves:franta-dxh"))
        environment.addPreset(preset)
        let wall = Wall(name: "Agents", tiles: [Tile(presetID: preset.id, size: .extraLarge)])
        environment.setWalls([wall])

        try withPasteboard { pasteboard in
            #expect(environment.copyWallAsJSON(wall, to: pasteboard) == nil)
            let file = try environment.configurationOnPasteboard(pasteboard).get()
            #expect(file.presets.map(\.id) == [preset.id])
            #expect(!environment.pastePreview(file).hasChanges)
        }
    }

    @Test("a version 1 file pastes through the configuration exactly as PresetTransfer reads it")
    func versionOnePaste() throws {
        let environment = environment()
        let preset = Preset(name: "Bugs", kinds: [.issue], filter: ItemFilter(query: "label:bug"), sort: .priority)

        try withPasteboard { pasteboard in
            pasteboard.clearContents()
            let text = PresetTransfer.encode([preset])
            pasteboard.setString(text, forType: .string)
            let file = try environment.configurationOnPasteboard(pasteboard).get()
            #expect(file.presets == (try PresetTransfer.decode(text).get()))
            #expect(file.walls.isEmpty)
        }
    }

    @Test("Copy Configuration as JSON pasted into an empty Gitwall gives the same presets and walls")
    func copyConfigurationRoundTrip() throws {
        let source = environment()
        let mine = Preset(name: "Mine", kinds: [.pullRequest], filter: ItemFilter(query: "author:@me"))
        let bugs = Preset(name: "Bugs", icon: "ladybug", kinds: [.issue], filter: ItemFilter(query: "label:bug"), sort: .priority)
        source.addPreset(mine)
        source.addPreset(bugs)
        source.setWalls([
            Wall(name: "Desk", tiles: [Tile(presetID: mine.id, size: .small), Tile(presetID: bugs.id, size: .large)]),
            Wall(name: "Bugs", tiles: [Tile(presetID: bugs.id)]),
        ])
        let target = environment()
        try #require(target.config.presets.isEmpty && target.config.walls.isEmpty)

        try withPasteboard { pasteboard in
            #expect(source.copyConfigurationAsJSON(to: pasteboard) == nil)
            target.pasteConfiguration(try target.configurationOnPasteboard(pasteboard).get())
        }

        // Tile ids are local to a Mac and not in the file (docs/adr/0014); everything else arrives as it was.
        func sameWalls(_ walls: [Wall]?) -> Bool {
            guard let walls, walls.map(\.id) == source.config.walls.map(\.id) else { return false }
            return zip(walls, source.config.walls).allSatisfy { $0.hasSameContent(as: $1) }
        }
        #expect(target.config.presets == source.config.presets)
        #expect(sameWalls(target.config.walls))
        #expect(sameWalls(try target.configStore?.load().walls))
    }

    @Test("every paste bumps the count the preset editor uses as its identity")
    func pasteCount() {
        let environment = environment()
        let before = environment.pasteCount
        environment.pasteConfiguration(GitwallFile(presets: [Preset(name: "Pasted")]))
        #expect(environment.pasteCount == before + 1)
    }

    @Test("a paste that replaces a wall forgets the Walls undo history, which would write over the pasted wall")
    func pasteForgetsUndo() {
        let environment = environment()
        let wall = Wall(name: "Desk")
        environment.setWalls([wall])
        let model = model(environment)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        undo.beginUndoGrouping()
        model.rename(wall.id, to: "Office")
        undo.endUndoGrouping()

        // Adding a wall leaves earlier edits undoable.
        environment.pasteConfiguration(GitwallFile(walls: [Wall(name: "Bugs")]))
        #expect(undo.canUndo)

        var pasted = wall
        pasted.name = "Pasted"
        environment.pasteConfiguration(GitwallFile(walls: [pasted]))
        #expect(!undo.canUndo)
        #expect(environment.config.walls.map(\.name) == ["Pasted", "Bugs"])
    }

    @Test("switching walls while a name is typed keeps the typed name")
    func renameThenSwitch() {
        let environment = environment()
        environment.setWalls([Wall(name: "A"), Wall(name: "B")])
        let model = model(environment)
        model.beginRename()
        model.renameDraft = "Office"

        model.showWall(offset: 1)

        #expect(environment.config.walls.map(\.name) == ["Office", "B"])
        #expect(model.currentWall?.name == "B")
        #expect(model.renamingWallID == nil)
    }

    @Test("keys without a modifier act only while the Walls window is key and no name is typed")
    func plainKeysInTheKeyWindow() {
        let environment = environment()
        environment.enterSampleData()
        let model = model(environment)

        let behindPopover = model.state(isKeyWindow: false, isTyping: false)
        #expect(!WallsCommand.isEnabled(.nextTile, in: behindPopover))
        #expect(!WallsCommand.isEnabled(.openItem, in: behindPopover))
        #expect(WallsCommand.isEnabled(.nextWall, in: behindPopover))
        #expect(WallsCommand.isEnabled(.nextTile, in: model.state(isKeyWindow: true, isTyping: false)))

        model.beginRename()
        #expect(!WallsCommand.isEnabled(.nextTile, in: model.state(isKeyWindow: true, isTyping: false)))
    }

    @Test("every Walls command has a menu action of its own")
    func menuActions() {
        for command in WallsCommand.allCases {
            #expect(WallsMenu.command(for: WallsMenu.selector(for: command)) == command)
        }
    }

    @Test("a change to the walls alone keeps the filtered items; a change to a preset works them out again")
    func wallsKeepTheCache() throws {
        let environment = environment()
        environment.enterSampleData()
        var review = try #require(environment.config.presets.first { $0.name == "Waiting for my review" })
        _ = environment.count(for: review)
        #expect(environment.filterCache.count == 1)

        environment.setWalls([])
        #expect(environment.filterCache.count == 1)

        review.name = "Reviews"
        environment.updatePreset(review)
        #expect(environment.filterCache.count == 0)
    }

    @Test("items are worked out again after a new snapshot and after a configuration change")
    func itemsCache() async throws {
        let environment = environment()
        environment.enterSampleData()
        var review = try #require(environment.config.presets.first { $0.name == "Waiting for my review" })
        let before = environment.count(for: review)
        #expect(environment.count(for: review) == before)

        // Refresh with sample data brings one more review request in a new snapshot.
        await environment.refresh()
        #expect(environment.count(for: review) == before + 1)

        review.filter = ItemFilter(query: "is:issue")
        environment.updatePreset(review)
        #expect(environment.count(for: review) == 0)
    }
}
