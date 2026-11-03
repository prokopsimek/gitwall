import Foundation

/// Why pasted text could not be read as a Gitwall file, phrased so the paste alert can show it as it is.
public enum GitwallFileError: Error, Equatable, Hashable, Sendable {
    /// A version 1 file or a bare list of presets, read by ``PresetTransfer`` exactly as Paste Presets always has.
    case presetFile(PresetTransferError)
    case noText
    case invalidJSON
    /// Valid JSON, but not an object with a `version`, nor a list of presets.
    case notAGitwallFile
    /// Keys next to `version`, `presets` and `walls`, sorted.
    case unknownKeys([String])
    case missingVersion
    /// The `version` value as it was written.
    case unsupportedVersion(String)
    /// A version 1 file with `walls` in it.
    case wallsNeedVersion2
    /// `presets` or `walls` is there but is not a list.
    case notAList(String)
    /// Neither presets nor walls.
    case empty
    /// `position` counts from 1, as the alert shows it. `name` is nil when the preset has no usable name.
    case invalidPreset(position: Int, name: String?, problem: PresetProblem)
    case invalidWall(position: Int, name: String?, problem: WallProblem)

    /// English, user-facing.
    public var message: String {
        switch self {
        case .presetFile(let error):
            error.message
        case .noText:
            "There is no text to read. Copy the JSON of your presets and walls first."
        case .invalidJSON:
            "The text is not valid JSON."
        case .notAGitwallFile:
            #"Expected {"version": 2, "presets": […], "walls": […]} or a list of presets."#
        case .unknownKeys(let keys):
            "Unknown \(keys.count == 1 ? "key" : "keys") \(PresetTransfer.quoted(keys)). A Gitwall file takes \(PresetTransfer.quoted(GitwallFile.FileKey.allCases.map(\.rawValue)))."
        case .missingVersion:
            #"“version” is missing. A file with walls starts with "version": 2."#
        case .unsupportedVersion(let value):
            "Version \(value) is not supported. This Gitwall reads versions 1 and 2."
        case .wallsNeedVersion2:
            #"Walls need "version": 2. Version 1 holds presets only."#
        case .notAList(let key):
            "“\(key)” must be a list."
        case .empty:
            "The file holds no presets and no walls."
        case .invalidPreset(let position, let name, let problem):
            PresetTransferError.invalidPreset(position: position, name: name, problem: problem).message
        case .invalidWall(let position, let name, .invalidTile(let tile, let problem)):
            "Wall \(position)\(name.map { " (“\($0)”)" } ?? ""), tile \(tile): \(problem.message)"
        case .invalidWall(let position, let name, let problem):
            "Wall \(position)\(name.map { " (“\($0)”)" } ?? ""): \(problem.message)"
        }
    }
}

/// What is wrong with one wall of a pasted file.
public enum WallProblem: Error, Equatable, Hashable, Sendable {
    public enum ValueType: Equatable, Hashable, Sendable {
        case string
        case list
    }

    case notAnObject
    /// Sorted.
    case unknownKeys([String])
    case missingKey(String)
    case wrongType(key: String, expected: ValueType)
    case invalidID(String)
    case duplicateID(firstPosition: Int)
    case emptyName
    /// `position` counts from 1.
    case invalidTile(position: Int, problem: TileProblem)

    public var message: String {
        switch self {
        case .notAnObject:
            "it is not an object with an id, a name and tiles."
        case .unknownKeys(let keys):
            "unknown \(keys.count == 1 ? "key" : "keys") \(PresetTransfer.quoted(keys)). A wall takes \(PresetTransfer.quoted(GitwallFile.WallKey.allCases.map(\.rawValue)))."
        case .missingKey(let key):
            "“\(key)” is missing."
        case .wrongType(let key, .string):
            "“\(key)” must be a string."
        case .wrongType(let key, .list):
            "“\(key)” must be a list."
        case .invalidID(let id):
            "“\(id)” is not a UUID. Generate one with uuidgen."
        case .duplicateID(let first):
            "it has the same id as wall \(first)."
        case .emptyName:
            "the name is empty."
        case .invalidTile(let position, let problem):
            "tile \(position): \(problem.message)"
        }
    }
}

/// What is wrong with one tile of a pasted wall.
public enum TileProblem: Error, Equatable, Hashable, Sendable {
    case notAnObject
    /// Sorted.
    case unknownKeys([String])
    case missingKey(String)
    /// The value of that key must be a string.
    case wrongType(key: String)
    case invalidPresetID(String)
    /// The preset id as written; it is neither among the pasted presets nor in the app.
    case unknownPreset(String)
    case unknownSize(String)

    public var message: String {
        switch self {
        case .notAnObject:
            "it is not an object with a preset and a size."
        case .unknownKeys(let keys):
            "unknown \(keys.count == 1 ? "key" : "keys") \(PresetTransfer.quoted(keys)). A tile takes \(PresetTransfer.quoted(GitwallFile.TileKey.allCases.map(\.rawValue)))."
        case .missingKey(let key):
            "“\(key)” is missing."
        case .wrongType(let key):
            "“\(key)” must be a string."
        case .invalidPresetID(let id):
            "“\(id)” is not a UUID."
        case .unknownPreset(let id):
            "the preset “\(id)” is neither in the file nor in Gitwall."
        case .unknownSize(let size):
            "unknown size “\(size)”. Use \(PresetTransfer.alternatives(TileSize.allCases.map(\.rawValue)))."
        }
    }
}

/// What pasting a Gitwall file does: the presets first, by the rules of ``PresetTransfer/merge(_:into:)``, then the
/// walls.
public struct GitwallFileMerge: Equatable, Sendable {
    public var presets: PresetMerge
    public var walls: [Wall]
    public var wallsAdded: Int
    public var wallsReplaced: Int
    public var wallsUnchanged: Int

    public init(presets: PresetMerge, walls: [Wall], wallsAdded: Int, wallsReplaced: Int, wallsUnchanged: Int) {
        self.presets = presets
        self.walls = walls
        self.wallsAdded = wallsAdded
        self.wallsReplaced = wallsReplaced
        self.wallsUnchanged = wallsUnchanged
    }

    public var hasChanges: Bool { presets.hasChanges || wallsAdded + wallsReplaced > 0 }

    /// A wall already here gets new content. Undoing an earlier edit of it would write the old content over the
    /// pasted one, so the Walls window forgets its undo history.
    public var replacesWalls: Bool { wallsReplaced > 0 }

    /// "2 new walls, 10 presets replaced", plus how many stay as they are. Counts of zero are left out.
    public var summary: String {
        func noun(_ word: String, _ number: Int) -> String { number == 1 ? word : word + "s" }
        var parts: [String] = []
        if wallsAdded > 0 { parts.append("\(wallsAdded) new \(noun("wall", wallsAdded))") }
        if wallsReplaced > 0 { parts.append("\(wallsReplaced) \(noun("wall", wallsReplaced)) replaced") }
        if presets.added > 0 { parts.append("\(presets.added) new \(noun("preset", presets.added))") }
        if presets.replaced > 0 { parts.append("\(presets.replaced) \(noun("preset", presets.replaced)) replaced") }
        let unchanged = presets.unchanged + wallsUnchanged
        if unchanged > 0 { parts.append("\(unchanged) unchanged") }
        return parts.joined(separator: ", ")
    }

    /// What the confirmation explains after the counts: what happens to a replaced preset or wall, only when the paste
    /// replaces one, and always that nothing is deleted.
    public var notes: [PasteNote] {
        var notes: [PasteNote] = []
        if presets.replaced > 0 { notes.append(.replacedPresetsKeepLocalSettings) }
        if replacesWalls { notes.append(.replacedWallsTakePastedContent) }
        notes.append(.nothingIsDeleted)
        return notes
    }
}

/// A rule of pasting that the confirmation states (``GitwallFileMerge/notes``). The app words them.
public enum PasteNote: Equatable, Sendable {
    /// A replaced preset keeps its accounts and repositories, notifications and menu bar count; its other filters give
    /// way to the pasted query (`docs/adr/0013`).
    case replacedPresetsKeepLocalSettings
    /// A replaced wall takes the pasted name and tiles (`docs/adr/0014`).
    case replacedWallsTakePastedContent
    /// A paste never deletes a preset or a wall.
    case nothingIsDeleted
}

/// Presets and walls in one portable JSON file, so a whole setup pastes in one step. Version 2 of the preset file
/// (`docs/adr/0013`); see `docs/adr/0014-walls-travel-with-presets-in-one-file.md`.
///
/// ```json
/// { "version": 2,
///   "presets": [ { "id": "6F0C2D6A-…", "name": "Mine", "query": "assignee:@me" } ],
///   "walls": [ { "id": "3C1F6A70-…", "name": "Desk", "tiles": [ { "preset": "6F0C2D6A-…", "size": "large" } ] } ] }
/// ```
///
/// A version 1 file and a bare list of presets are read by ``PresetTransfer`` exactly as before. A tile names its
/// preset by id and its size; tile ids, rotation and zoom are choices of one Mac and stay out of the file.
public struct GitwallFile: Equatable, Sendable {
    public static let version = 2

    public var presets: [Preset]
    /// Tiles get new local ids when read; ``Wall/hasSameContent(as:)`` compares walls without them.
    public var walls: [Wall]

    public init(presets: [Preset] = [], walls: [Wall] = []) {
        self.presets = presets
        self.walls = walls
    }

    enum FileKey: String, CaseIterable {
        case version, presets, walls
    }

    enum WallKey: String, CaseIterable {
        case id, name, tiles
    }

    enum TileKey: String, CaseIterable {
        case preset, size
    }

    // MARK: Reading

    /// Reads a version 2 file, or hands a version 1 file or a bare list of presets to ``PresetTransfer``. Everything
    /// is checked before anything is returned, so a paste either succeeds whole or changes nothing.
    /// - Parameters:
    ///   - presetsInApp: Ids of the presets Gitwall already has. A tile may point at one of them or at a preset of
    ///     the file.
    ///   - iconExists: Whether an SF Symbol of that name exists; see ``PresetTransfer/decode(_:iconExists:)``.
    public static func decode(
        _ text: String,
        presetsInApp: Set<UUID>,
        iconExists: (String) -> Bool = { _ in true }
    ) -> Result<GitwallFile, GitwallFileError> {
        guard !PresetTransfer.isBlank(text) else { return .failure(.noText) }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            return .failure(.invalidJSON)
        }

        switch json {
        case .array:
            return presetFile(text, iconExists: iconExists)
        case .object(let file):
            let hasWalls = file[FileKey.walls.rawValue] != nil
            switch file[FileKey.version.rawValue] {
            case .number(Double(PresetTransfer.version))?:
                return hasWalls ? .failure(.wallsNeedVersion2) : presetFile(text, iconExists: iconExists)
            case nil:
                return hasWalls ? .failure(.missingVersion) : presetFile(text, iconExists: iconExists)
            case .number(Double(version))?:
                return decodeVersion2(file, presetsInApp: presetsInApp, iconExists: iconExists)
            case let other?:
                return .failure(.unsupportedVersion(other.written))
            }
        default:
            return .failure(.notAGitwallFile)
        }
    }

    private static func presetFile(_ text: String, iconExists: (String) -> Bool) -> Result<GitwallFile, GitwallFileError> {
        PresetTransfer.decode(text, iconExists: iconExists)
            .map { GitwallFile(presets: $0) }
            .mapError { .presetFile($0) }
    }

    private static func decodeVersion2(
        _ file: [String: JSONValue],
        presetsInApp: Set<UUID>,
        iconExists: (String) -> Bool
    ) -> Result<GitwallFile, GitwallFileError> {
        let unknown = Set(file.keys).subtracting(FileKey.allCases.map(\.rawValue))
        guard unknown.isEmpty else { return .failure(.unknownKeys(unknown.sorted())) }

        func list(_ key: FileKey) -> Result<[JSONValue], GitwallFileError> {
            switch file[key.rawValue] {
            case nil: .success([])
            case .array(let entries)?: .success(entries)
            default: .failure(.notAList(key.rawValue))
            }
        }

        do throws(GitwallFileError) {
            let presetEntries = try list(.presets).get()
            let wallEntries = try list(.walls).get()
            guard !presetEntries.isEmpty || !wallEntries.isEmpty else { return .failure(.empty) }

            let presets = try PresetTransfer.presets(from: presetEntries, iconExists: iconExists)
                .mapError { GitwallFileError.invalidPreset(position: $0.position, name: $0.name, problem: $0.problem) }
                .get()

            let knownPresets = presetsInApp.union(presets.map(\.id))
            var walls: [Wall] = []
            var wallPositions: [UUID: Int] = [:]
            for (offset, entry) in wallEntries.enumerated() {
                let position = offset + 1
                switch wall(from: entry, knownPresets: knownPresets) {
                case .failure(let problem):
                    throw .invalidWall(position: position, name: PresetTransfer.usableName(of: entry), problem: problem)
                case .success(let wall):
                    if let first = wallPositions[wall.id] {
                        throw .invalidWall(position: position, name: wall.name, problem: .duplicateID(firstPosition: first))
                    }
                    wallPositions[wall.id] = position
                    walls.append(wall)
                }
            }
            return .success(GitwallFile(presets: presets, walls: walls))
        } catch {
            return .failure(error)
        }
    }

    private static func wall(from entry: JSONValue, knownPresets: Set<UUID>) -> Result<Wall, WallProblem> {
        guard case .object(let fields) = entry else { return .failure(.notAnObject) }
        let unknown = Set(fields.keys).subtracting(WallKey.allCases.map(\.rawValue))
        guard unknown.isEmpty else { return .failure(.unknownKeys(unknown.sorted())) }

        func required(_ key: WallKey) -> Result<String, WallProblem> {
            switch fields[key.rawValue] {
            case nil: .failure(.missingKey(key.rawValue))
            case .string(let value)?: .success(value)
            default: .failure(.wrongType(key: key.rawValue, expected: .string))
            }
        }

        do throws(WallProblem) {
            let rawID = try required(.id).get()
            guard let id = UUID(uuidString: rawID) else { return .failure(.invalidID(rawID)) }
            let name = try required(.name).get()
            guard !PresetTransfer.isBlank(name) else { return .failure(.emptyName) }

            var tiles: [Tile] = []
            switch fields[WallKey.tiles.rawValue] {
            case nil:
                break
            case .array(let entries)?:
                for (offset, entry) in entries.enumerated() {
                    switch tile(from: entry, knownPresets: knownPresets) {
                    case .failure(let problem): return .failure(.invalidTile(position: offset + 1, problem: problem))
                    case .success(let tile): tiles.append(tile)
                    }
                }
            default:
                return .failure(.wrongType(key: WallKey.tiles.rawValue, expected: .list))
            }
            return .success(Wall(id: id, name: name, tiles: tiles))
        } catch {
            return .failure(error)
        }
    }

    private static func tile(from entry: JSONValue, knownPresets: Set<UUID>) -> Result<Tile, TileProblem> {
        guard case .object(let fields) = entry else { return .failure(.notAnObject) }
        let unknown = Set(fields.keys).subtracting(TileKey.allCases.map(\.rawValue))
        guard unknown.isEmpty else { return .failure(.unknownKeys(unknown.sorted())) }

        guard let rawPreset = fields[TileKey.preset.rawValue] else { return .failure(.missingKey(TileKey.preset.rawValue)) }
        guard case .string(let presetText) = rawPreset else { return .failure(.wrongType(key: TileKey.preset.rawValue)) }
        guard let presetID = UUID(uuidString: presetText) else { return .failure(.invalidPresetID(presetText)) }
        guard knownPresets.contains(presetID) else { return .failure(.unknownPreset(presetText)) }

        var size = TileSize.medium
        if let rawSize = fields[TileKey.size.rawValue] {
            guard case .string(let sizeText) = rawSize else { return .failure(.wrongType(key: TileKey.size.rawValue)) }
            guard let value = TileSize(rawValue: sizeText) else { return .failure(.unknownSize(sizeText)) }
            size = value
        }
        return .success(Tile(presetID: presetID, size: size))
    }

    // MARK: Writing

    /// Version 2, pretty-printed with sorted keys, every key of every preset, wall and tile, so reading it back
    /// gives the same presets and walls and writing those again gives the same text.
    public static func encode(presets: [Preset], walls: [Wall]) -> String {
        let file = File(
            version: version,
            presets: presets.map(PresetTransfer.Entry.init),
            walls: walls.map { wall in
                WallEntry(id: wall.id, name: wall.name, tiles: wall.tiles.map { TileEntry(preset: $0.presetID, size: $0.size) })
            }
        )
        guard let data = try? SnapshotCoding.encode(file) else {
            preconditionFailure("Presets and walls of strings and UUIDs could not be encoded")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// One wall with the presets its tiles use, in the order of `presets` (the app's), so the text pastes into
    /// another Gitwall as it is. A tile whose preset is gone is left out; ``copyWarning(for:presets:)`` says so.
    public static func encode(wall: Wall, presets: [Preset]) -> String {
        let (kept, _) = exportable([wall], presets: presets)
        return encode(presets: usedPresets(by: kept, in: presets), walls: kept)
    }

    /// Every preset and every wall: the whole setup of this Mac as one file. Tiles whose preset is gone are left out;
    /// ``copyWarning(presets:walls:)`` says so.
    public static func encodeConfiguration(presets: [Preset], walls: [Wall]) -> String {
        encode(presets: presets, walls: exportable(walls, presets: presets).walls)
    }

    /// What ``encode(wall:presets:)`` leaves out, or nil when nothing: tiles of deleted presets, and what the
    /// presets lose in the file (``PresetTransfer/copyWarning(for:)``).
    public static func copyWarning(for wall: Wall, presets: [Preset]) -> String? {
        let (kept, dropped) = exportable([wall], presets: presets)
        return warning(droppedTiles: dropped, presets: usedPresets(by: kept, in: presets))
    }

    /// What ``encodeConfiguration(presets:walls:)`` leaves out, or nil when nothing.
    public static func copyWarning(presets: [Preset], walls: [Wall]) -> String? {
        warning(droppedTiles: exportable(walls, presets: presets).dropped, presets: presets)
    }

    private static func warning(droppedTiles dropped: Int, presets: [Preset]) -> String? {
        let tiles = dropped == 0 ? nil : "\(dropped) \(dropped == 1 ? "tile shows a preset that was" : "tiles show presets that were") deleted and \(dropped == 1 ? "is" : "are") left out."
        let warnings = [tiles, PresetTransfer.copyWarning(for: presets)].compactMap(\.self)
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    /// The walls without tiles of presets that are gone, and how many tiles that left out.
    private static func exportable(_ walls: [Wall], presets: [Preset]) -> (walls: [Wall], dropped: Int) {
        let available = Set(presets.map(\.id))
        var dropped = 0
        let kept = walls.map { wall in
            var kept = wall
            kept.tiles.removeAll { !available.contains($0.presetID) }
            dropped += wall.tiles.count - kept.tiles.count
            return kept
        }
        return (kept, dropped)
    }

    /// The presets the tiles of `walls` show, in the order of `presets`.
    private static func usedPresets(by walls: [Wall], in presets: [Preset]) -> [Preset] {
        let used = Set(walls.flatMap(\.tiles).map(\.presetID))
        return presets.filter { used.contains($0.id) }
    }

    private struct File: Encodable {
        let version: Int
        let presets: [PresetTransfer.Entry]
        let walls: [WallEntry]
    }

    private struct WallEntry: Encodable {
        let id: UUID
        let name: String
        let tiles: [TileEntry]
    }

    private struct TileEntry: Encodable {
        let preset: UUID
        let size: TileSize
    }

    // MARK: Merging

    /// Presets merge by the rules of ``PresetTransfer/merge(_:into:)``. A wall whose id is already here is replaced
    /// whole, name and tiles, in its place; a new id is appended; walls not in the file stay as they are. Nothing is
    /// ever removed.
    public static func merge(_ file: GitwallFile, presets: [Preset], walls: [Wall]) -> GitwallFileMerge {
        var result = GitwallFileMerge(
            presets: PresetTransfer.merge(file.presets, into: presets),
            walls: walls, wallsAdded: 0, wallsReplaced: 0, wallsUnchanged: 0
        )
        for wall in file.walls {
            if let index = result.walls.firstIndex(where: { $0.id == wall.id }) {
                if result.walls[index].hasSameContent(as: wall) {
                    result.wallsUnchanged += 1
                } else {
                    result.walls[index] = wall
                    result.wallsReplaced += 1
                }
            } else {
                result.walls.append(wall)
                result.wallsAdded += 1
            }
        }
        return result
    }
}
