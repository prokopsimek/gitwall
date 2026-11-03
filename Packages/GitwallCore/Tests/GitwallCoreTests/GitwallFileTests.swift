import Foundation
import Testing
@testable import GitwallCore

@Suite("Gitwall file")
struct GitwallFileTests {
    let reviewID = UUID(uuidString: "6F0C2D6A-1B7E-4C55-9E0A-2D8E4B1F7A10")!
    let bugsID = UUID(uuidString: "0B5E9C3E-77A2-4F1D-8C64-5A9D2E7F3B21")!
    let deskID = UUID(uuidString: "3C1F6A70-5D2B-4E8A-9B47-0F2C6D8E1A35")!
    let teamID = UUID(uuidString: "9A4E2B18-7C63-4D05-8F1A-6B3D2C9E7F40")!

    private func decode(_ text: String, inApp: Set<UUID> = []) -> Result<GitwallFile, GitwallFileError> {
        GitwallFile.decode(text, presetsInApp: inApp)
    }

    private func failure(_ text: String, inApp: Set<UUID> = []) -> GitwallFileError? {
        if case .failure(let error) = decode(text, inApp: inApp) { return error }
        return nil
    }

    private var presetJSON: String { #"{"id": "\#(reviewID)", "name": "Review", "query": "review-requested:@me"}"# }

    // MARK: - Version 1 stays as it was

    @Test("a version 1 file and a bare list read exactly as Paste Presets reads them")
    func versionOne() throws {
        let texts = [
            #"{"version": 1, "presets": [\#(presetJSON)]}"#,
            "[\(presetJSON)]",
        ]
        for text in texts {
            let file = try decode(text).get()
            #expect(file.presets == (try PresetTransfer.decode(text).get()))
            #expect(file.walls.isEmpty)
        }
    }

    @Test("errors in a version 1 file are the errors Paste Presets gives")
    func versionOneErrors() {
        let text = #"{"version": 1, "presets": [{"id": "x", "name": "A", "query": ""}]}"#
        guard case .failure(let presetError) = PresetTransfer.decode(text) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure(text) == .presetFile(presetError))
        #expect(failure(#"{"presets": []}"#) == .presetFile(.missingVersion))
        #expect(failure(#"{"presets": []}"#)?.message == PresetTransferError.missingVersion.message)
    }

    @Test("walls need version 2")
    func wallsNeedVersionTwo() {
        #expect(failure(#"{"version": 1, "presets": [\#(presetJSON)], "walls": []}"#) == .wallsNeedVersion2)
        #expect(failure(#"{"presets": [\#(presetJSON)], "walls": []}"#) == .missingVersion)
        #expect(failure(#"{"version": 3, "walls": []}"#) == .unsupportedVersion("3"))
        #expect(GitwallFileError.unsupportedVersion("3").message.contains("versions 1 and 2"))
    }

    // MARK: - Version 2

    @Test("a version 2 file carries presets and walls; a tile may use a preset from the file or from the app")
    func versionTwo() throws {
        let text = """
        {
          "version": 2,
          "presets": [\(presetJSON)],
          "walls": [
            {"id": "\(deskID)", "name": "Desk", "tiles": [
              {"preset": "\(reviewID)", "size": "large"},
              {"preset": "\(bugsID.uuidString.lowercased())"}
            ]}
          ]
        }
        """
        let file = try decode(text, inApp: [bugsID]).get()

        #expect(file.presets.map(\.id) == [reviewID])
        #expect(file.walls.count == 1)
        let wall = file.walls[0]
        #expect(wall.id == deskID)
        #expect(wall.name == "Desk")
        #expect(wall.tiles.map(\.presetID) == [reviewID, bugsID])
        // A tile without a size is medium.
        #expect(wall.tiles.map(\.size) == [.large, .medium])
    }

    @Test("a version 2 file may hold only walls or only presets, but not nothing")
    func partialFiles() throws {
        let wallsOnly = #"{"version": 2, "walls": [{"id": "\#(deskID)", "name": "Desk", "tiles": []}]}"#
        #expect(try decode(wallsOnly).get().walls.map(\.id) == [deskID])
        #expect(try decode(#"{"version": 2, "presets": [\#(presetJSON)]}"#).get().presets.map(\.id) == [reviewID])
        // A wall without tiles is a wall to fill in later.
        #expect(try decode(#"{"version": 2, "walls": [{"id": "\#(deskID)", "name": "Desk"}]}"#).get().walls[0].tiles.isEmpty)
        #expect(failure(#"{"version": 2}"#) == .empty)
        #expect(failure(#"{"version": 2, "presets": [], "walls": []}"#) == .empty)
    }

    @Test("the file itself is checked: JSON, keys and lists")
    func fileErrors() {
        #expect(failure("") == .noText)
        #expect(failure("walls") == .invalidJSON)
        #expect(failure("42") == .notAGitwallFile)
        #expect(failure(#"{"version": 2, "walls": [], "wall": []}"#) == .unknownKeys(["wall"]))
        #expect(failure(#"{"version": 2, "walls": {}}"#) == .notAList("walls"))
        #expect(failure(#"{"version": 2, "presets": "x"}"#) == .notAList("presets"))
    }

    @Test("presets in a version 2 file are checked like pasted presets")
    func presetErrors() {
        let duplicate = #"{"version": 2, "presets": [\#(presetJSON), \#(presetJSON)]}"#
        #expect(failure(duplicate) == .invalidPreset(position: 2, name: "Review", problem: .duplicateID(firstPosition: 1)))
        let badQuery = #"{"version": 2, "presets": [{"id": "\#(reviewID)", "name": "Review", "query": "nope:x"}]}"#
        #expect(failure(badQuery) == .invalidPreset(position: 1, name: "Review", problem: .invalidQuery(.unknownQualifier("nope"))))
        let icon = #"{"version": 2, "presets": [{"id": "\#(reviewID)", "name": "Review", "query": "", "icon": "no.such"}]}"#
        #expect(GitwallFile.decode(icon, presetsInApp: [], iconExists: { _ in false })
            == .failure(.invalidPreset(position: 1, name: "Review", problem: .unknownIcon("no.such"))))
    }

    @Test("a wall is checked key by key, and the message names it")
    func wallErrors() {
        func wall(_ body: String) -> String { #"{"version": 2, "walls": [\#(body)]}"# }

        #expect(failure(wall(#""Desk""#)) == .invalidWall(position: 1, name: nil, problem: .notAnObject))
        #expect(failure(wall(#"{"id": "\#(deskID)", "name": "Desk", "tile": []}"#))
            == .invalidWall(position: 1, name: "Desk", problem: .unknownKeys(["tile"])))
        #expect(failure(wall(#"{"name": "Desk"}"#)) == .invalidWall(position: 1, name: "Desk", problem: .missingKey("id")))
        #expect(failure(wall(#"{"id": "\#(deskID)"}"#)) == .invalidWall(position: 1, name: nil, problem: .missingKey("name")))
        #expect(failure(wall(#"{"id": "desk", "name": "Desk"}"#)) == .invalidWall(position: 1, name: "Desk", problem: .invalidID("desk")))
        #expect(failure(wall(#"{"id": "\#(deskID)", "name": " "}"#)) == .invalidWall(position: 1, name: nil, problem: .emptyName))
        #expect(failure(wall(#"{"id": "\#(deskID)", "name": 1}"#))
            == .invalidWall(position: 1, name: nil, problem: .wrongType(key: "name", expected: .string)))
        #expect(failure(wall(#"{"id": "\#(deskID)", "name": "Desk", "tiles": {}}"#))
            == .invalidWall(position: 1, name: "Desk", problem: .wrongType(key: "tiles", expected: .list)))
        let twice = #"{"version": 2, "walls": [{"id": "\#(deskID)", "name": "A"}, {"id": "\#(deskID.uuidString.lowercased())", "name": "B"}]}"#
        #expect(failure(twice) == .invalidWall(position: 2, name: "B", problem: .duplicateID(firstPosition: 1)))
    }

    @Test("a tile is checked too: its keys, its preset and its size")
    func tileErrors() {
        func tiles(_ body: String) -> String {
            #"{"version": 2, "presets": [\#(presetJSON)], "walls": [{"id": "\#(deskID)", "name": "Desk", "tiles": [\#(body)]}]}"#
        }
        func tileProblem(_ position: Int, _ problem: TileProblem) -> GitwallFileError {
            .invalidWall(position: 1, name: "Desk", problem: .invalidTile(position: position, problem: problem))
        }

        #expect(failure(tiles(#""large""#)) == tileProblem(1, .notAnObject))
        #expect(failure(tiles(#"{"preset": "\#(reviewID)", "size": "large", "title": "x"}"#)) == tileProblem(1, .unknownKeys(["title"])))
        #expect(failure(tiles(#"{"size": "large"}"#)) == tileProblem(1, .missingKey("preset")))
        #expect(failure(tiles(#"{"preset": 1}"#)) == tileProblem(1, .wrongType(key: "preset")))
        #expect(failure(tiles(#"{"preset": "review"}"#)) == tileProblem(1, .invalidPresetID("review")))
        #expect(failure(tiles(#"{"preset": "\#(reviewID)"}, {"preset": "\#(bugsID)"}"#)) == tileProblem(2, .unknownPreset(bugsID.uuidString)))
        #expect(failure(tiles(#"{"preset": "\#(reviewID)", "size": "huge"}"#)) == tileProblem(1, .unknownSize("huge")))
        #expect(failure(tiles(#"{"preset": "\#(reviewID)", "size": 3}"#)) == tileProblem(1, .wrongType(key: "size")))
    }

    @Test("messages name the wall by position and name, and the tile by position")
    func messages() {
        let missing = GitwallFileError.invalidWall(position: 2, name: "Agents", problem: .invalidTile(position: 3, problem: .unknownPreset(bugsID.uuidString)))
        #expect(missing.message == "Wall 2 (“Agents”), tile 3: the preset “\(bugsID.uuidString)” is neither in the file nor in Gitwall.")
        let size = GitwallFileError.invalidWall(position: 1, name: nil, problem: .invalidTile(position: 1, problem: .unknownSize("huge")))
        #expect(size.message == "Wall 1, tile 1: unknown size “huge”. Use small, medium, large or extraLarge.")
        let preset = GitwallFileError.invalidPreset(position: 2, name: "Agents", problem: .invalidQuery(.unclosedParenthesis))
        #expect(preset.message == PresetTransferError.invalidPreset(position: 2, name: "Agents", problem: .invalidQuery(.unclosedParenthesis)).message)
        #expect(GitwallFileError.wallsNeedVersion2.message.contains(#""version": 2"#))
    }

    // MARK: - Writing

    @Test("a written file reads back as the same presets and walls, and writes the same text again")
    func roundTrip() throws {
        let presets = [
            Preset(id: reviewID, name: "Review", icon: "eye", kinds: [.pullRequest], filter: ItemFilter(query: "review-requested:@me"), sort: .priority),
            Preset(id: bugsID, name: "Bugs", icon: "ladybug", kinds: [.issue], filter: ItemFilter(query: "label:bug")),
        ]
        let walls = [
            Wall(id: deskID, name: "Desk", tiles: [Tile(presetID: reviewID, size: .large), Tile(presetID: bugsID, size: .small)]),
            Wall(id: teamID, name: "Team", tiles: []),
        ]

        let text = GitwallFile.encode(presets: presets, walls: walls)
        let file = try decode(text).get()

        #expect(file.presets == presets)
        #expect(file.walls.count == 2)
        #expect(zip(file.walls, walls).allSatisfy { $0.hasSameContent(as: $1) && $0.id == $1.id })
        #expect(GitwallFile.encode(presets: file.presets, walls: file.walls) == text)
    }

    @Test("the file is version 2 with every key of every wall and tile")
    func shape() throws {
        let walls = [Wall(id: deskID, name: "Desk", tiles: [Tile(presetID: reviewID, size: .extraLarge)])]
        let object = try #require(try JSONSerialization.jsonObject(with: Data(GitwallFile.encode(presets: [], walls: walls).utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "presets", "walls"])
        #expect(object["version"] as? Int == 2)
        let wall = try #require((object["walls"] as? [[String: Any]])?.first)
        #expect(Set(wall.keys) == ["id", "name", "tiles"])
        let tile = try #require((wall["tiles"] as? [[String: Any]])?.first)
        #expect(tile as? [String: String] == ["preset": reviewID.uuidString, "size": "extraLarge"])
    }

    @Test("copying a wall brings the presets its tiles use, in the app's order, so it pastes anywhere")
    func copyWall() throws {
        let other = Preset(name: "Unused")
        let presets = [Preset(id: bugsID, name: "Bugs"), other, Preset(id: reviewID, name: "Review")]
        let wall = Wall(id: deskID, name: "Desk", tiles: [
            Tile(presetID: reviewID, size: .large), Tile(presetID: bugsID), Tile(presetID: reviewID, size: .small),
        ])

        let text = GitwallFile.encode(wall: wall, presets: presets)
        let file = try decode(text).get()

        #expect(file.presets.map(\.id) == [bugsID, reviewID])
        #expect(file.walls.count == 1)
        #expect(file.walls[0].hasSameContent(as: wall))
        #expect(GitwallFile.copyWarning(for: wall, presets: presets) == nil)
    }

    @Test("a tile whose preset was deleted is left out of the copy, and the warning says so")
    func copyWallWithDeletedPreset() throws {
        let presets = [Preset(id: reviewID, name: "Review", scopes: [PresetScope(accountID: UUID())])]
        let wall = Wall(id: deskID, name: "Desk", tiles: [Tile(presetID: reviewID), Tile(presetID: bugsID)])

        let file = try decode(GitwallFile.encode(wall: wall, presets: presets)).get()

        #expect(file.walls[0].tiles.map(\.presetID) == [reviewID])
        let warning = try #require(GitwallFile.copyWarning(for: wall, presets: presets))
        #expect(warning.contains("1 tile"))
        #expect(warning.contains("“Review” (accounts and repositories)"))
    }

    // MARK: - Merging

    @Test("presets merge first by the preset rules, then walls: same id replaced whole, new appended, others kept")
    func merge() {
        let keptWall = Wall(name: "Kept", tiles: [Tile(presetID: bugsID)])
        let oldDesk = Wall(id: deskID, name: "Old desk", tiles: [Tile(presetID: bugsID, size: .small)])
        let existingPresets = [Preset(id: bugsID, name: "Bugs", notifications: [.merged])]
        let file = GitwallFile(
            presets: [Preset(id: reviewID, name: "Review", filter: ItemFilter(query: "is:pr"))],
            walls: [
                Wall(id: deskID, name: "Desk", tiles: [Tile(presetID: reviewID, size: .large)]),
                Wall(id: teamID, name: "Team", tiles: [Tile(presetID: bugsID)]),
            ]
        )

        let merge = GitwallFile.merge(file, presets: existingPresets, walls: [oldDesk, keptWall])

        #expect(merge.presets.presets.map(\.id) == [bugsID, reviewID])
        #expect(merge.presets.added == 1)
        #expect(merge.walls.map(\.id) == [deskID, keptWall.id, teamID])
        #expect(merge.walls[0].name == "Desk")
        #expect(merge.walls[0].tiles.map(\.size) == [.large])
        #expect(merge.walls[1] == keptWall)
        #expect(merge.wallsAdded == 1 && merge.wallsReplaced == 1 && merge.wallsUnchanged == 0)
        #expect(merge.hasChanges)
        #expect(merge.summary == "1 new wall, 1 wall replaced, 1 new preset")
    }

    @Test("pasting what is already there changes nothing, and keeps the tiles as they were")
    func mergeUnchanged() {
        let desk = Wall(id: deskID, name: "Desk", tiles: [Tile(presetID: reviewID, size: .large)])
        let presets = [Preset(id: reviewID, name: "Review", kinds: [.pullRequest, .issue], filter: ItemFilter(query: "is:pr"))]
        var pasted = desk
        pasted.tiles = [Tile(presetID: reviewID, size: .large)]

        let merge = GitwallFile.merge(GitwallFile(presets: presets, walls: [pasted]), presets: presets, walls: [desk])

        #expect(!merge.hasChanges)
        #expect(merge.walls == [desk])
        #expect(merge.summary == "2 unchanged")
    }

    @Test("a paste replaces walls only when a wall with a known id changes")
    func replacesWalls() {
        let presets = PresetMerge(presets: [], added: 3, replaced: 1, unchanged: 0)
        #expect(!GitwallFileMerge(presets: presets, walls: [], wallsAdded: 2, wallsReplaced: 0, wallsUnchanged: 1).replacesWalls)
        #expect(GitwallFileMerge(presets: presets, walls: [], wallsAdded: 0, wallsReplaced: 1, wallsUnchanged: 0).replacesWalls)
    }

    // MARK: - The whole configuration

    @Test("copying the whole configuration and pasting it into an empty one gives the same presets and walls")
    func configurationRoundTrip() throws {
        let presets = [
            Preset(id: reviewID, name: "Review", icon: "eye", kinds: [.pullRequest], filter: ItemFilter(query: "review-requested:@me"), sort: .priority),
            Preset(id: bugsID, name: "Bugs", icon: "ladybug", kinds: [.issue], filter: ItemFilter(query: "label:bug")),
        ]
        let walls = [
            Wall(id: deskID, name: "Desk", tiles: [Tile(presetID: reviewID, size: .large), Tile(presetID: bugsID)]),
            Wall(id: teamID, name: "Team", tiles: [Tile(presetID: bugsID, size: .extraLarge)]),
        ]

        let text = GitwallFile.encodeConfiguration(presets: presets, walls: walls)
        let merge = GitwallFile.merge(try decode(text).get(), presets: [], walls: [])

        #expect(merge.presets.presets == presets)
        #expect(merge.walls.map(\.id) == walls.map(\.id))
        #expect(zip(merge.walls, walls).allSatisfy { $0.hasSameContent(as: $1) })
        #expect(GitwallFile.copyWarning(presets: presets, walls: walls) == nil)
    }

    @Test("every tile is written with its size, even the default one")
    func sizeAlwaysWritten() throws {
        let walls = [Wall(id: deskID, name: "Desk", tiles: [Tile(presetID: reviewID), Tile(presetID: reviewID, size: .small)])]
        let text = GitwallFile.encodeConfiguration(presets: [Preset(id: reviewID, name: "Review")], walls: walls)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let tiles = try #require((object["walls"] as? [[String: Any]])?.first?["tiles"] as? [[String: String]])
        #expect(tiles.map { $0["size"] } == ["medium", "small"])
    }

    @Test("the whole configuration leaves out tiles of deleted presets, and says how many")
    func configurationWithDeletedPreset() throws {
        let presets = [Preset(id: reviewID, name: "Review")]
        let walls = [
            Wall(id: deskID, name: "Desk", tiles: [Tile(presetID: reviewID), Tile(presetID: bugsID)]),
            Wall(id: teamID, name: "Team", tiles: [Tile(presetID: bugsID)]),
        ]

        let file = try decode(GitwallFile.encodeConfiguration(presets: presets, walls: walls)).get()

        #expect(file.walls.map(\.tiles.count) == [1, 0])
        let warning = try #require(GitwallFile.copyWarning(presets: presets, walls: walls))
        #expect(warning.contains("2 tiles"))
    }

    @Test("the confirmation explains what happens to replaced presets and walls only when the paste replaces some")
    func notes() {
        func merge(presetsReplaced: Int, wallsReplaced: Int) -> GitwallFileMerge {
            GitwallFileMerge(
                presets: PresetMerge(presets: [], added: 16, replaced: presetsReplaced, unchanged: 3),
                walls: [], wallsAdded: 3, wallsReplaced: wallsReplaced, wallsUnchanged: 1
            )
        }
        #expect(merge(presetsReplaced: 0, wallsReplaced: 0).notes == [.nothingIsDeleted])
        #expect(merge(presetsReplaced: 6, wallsReplaced: 0).notes == [.replacedPresetsKeepLocalSettings, .nothingIsDeleted])
        #expect(merge(presetsReplaced: 0, wallsReplaced: 1).notes == [.replacedWallsTakePastedContent, .nothingIsDeleted])
        #expect(merge(presetsReplaced: 2, wallsReplaced: 2).notes == [
            .replacedPresetsKeepLocalSettings, .replacedWallsTakePastedContent, .nothingIsDeleted,
        ])
    }

    @Test("the summary counts walls first, then presets, in the plural where needed")
    func summary() {
        let presets = PresetMerge(presets: [], added: 0, replaced: 10, unchanged: 0)
        let merge = GitwallFileMerge(presets: presets, walls: [], wallsAdded: 2, wallsReplaced: 0, wallsUnchanged: 0)
        #expect(merge.summary == "2 new walls, 10 presets replaced")
    }
}
