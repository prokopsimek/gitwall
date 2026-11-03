import Foundation
import GitwallCore
import Testing

/// `--debug-demo` and sample data show walls, so screenshots of the Walls window need no setup.
@Suite("Demo walls")
struct DemoWallsTests {
    @Test("sample walls use only sample presets, keep their ids from launch to launch and use every tile size")
    func walls() {
        let config = DemoData.config
        let presetIDs = Set(config.presets.map(\.id))
        #expect(config.walls.count >= 2)
        #expect(config.walls.allSatisfy { !$0.tiles.isEmpty })
        #expect(config.walls.flatMap(\.tiles).allSatisfy { presetIDs.contains($0.presetID) })
        #expect(Set(config.walls.flatMap(\.tiles).map(\.size)) == Set(TileSize.allCases))
        #expect(DemoData.config.walls == config.walls)
        let ids = config.walls.map(\.id) + config.walls.flatMap(\.tiles).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
