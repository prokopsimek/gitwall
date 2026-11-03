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

    @Test("a version 1 file pastes through the configuration exactly as through Paste Presets")
    func versionOnePaste() throws {
        let environment = environment()
        let preset = Preset(name: "Bugs", kinds: [.issue], filter: ItemFilter(query: "label:bug"), sort: .priority)

        try withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(PresetTransfer.encode([preset]), forType: .string)
            let file = try environment.configurationOnPasteboard(pasteboard).get()
            #expect(file.presets == (try environment.presetsOnPasteboard(pasteboard).get()))
            #expect(file.walls.isEmpty)
        }
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
