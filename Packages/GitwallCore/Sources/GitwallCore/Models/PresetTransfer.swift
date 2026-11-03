import Foundation

/// Why pasted text could not be read as presets, phrased so the paste alert can show it as it is.
public enum PresetTransferError: Error, Equatable, Hashable, Sendable {
    case noText
    case invalidJSON
    /// Valid JSON, but neither `{"version": 1, "presets": […]}` nor a bare list of presets.
    case notAPresetFile
    /// Keys next to `version` and `presets`, sorted.
    case unknownKeys([String])
    case missingVersion
    /// The `version` value as it was written, for example `2` or `"1"`.
    case unsupportedVersion(String)
    case missingPresets
    case noPresets
    /// `position` counts from 1, as the alert shows it. `name` is nil when the preset has no usable name.
    case invalidPreset(position: Int, name: String?, problem: PresetProblem)

    /// English, user-facing.
    public var message: String {
        switch self {
        case .noText:
            "There is no text to read. Copy the JSON of your presets first."
        case .invalidJSON:
            "The text is not valid JSON."
        case .notAPresetFile:
            #"Expected {"version": 1, "presets": […]} or a list of presets."#
        case .unknownKeys(let keys):
            "Unknown \(keys.count == 1 ? "key" : "keys") \(PresetTransfer.quoted(keys)) next to “presets”. Only “version” and “presets” belong there."
        case .missingVersion:
            #"“version” is missing. Write "version": 1, or paste the list of presets alone."#
        case .unsupportedVersion(let value):
            "Version \(value) is not supported. This Gitwall reads version \(PresetTransfer.version)."
        case .missingPresets:
            "“presets” is missing."
        case .noPresets:
            "The list holds no presets."
        case .invalidPreset(let position, let name, let problem):
            "Preset \(position)\(name.map { " (“\($0)”)" } ?? ""): \(problem.message)"
        }
    }
}

/// What is wrong with one preset of a pasted list.
public enum PresetProblem: Error, Equatable, Hashable, Sendable {
    public enum ValueType: Equatable, Hashable, Sendable {
        case string
        case listOfStrings
    }

    case notAnObject
    /// Sorted.
    case unknownKeys([String])
    case missingKey(String)
    case wrongType(key: String, expected: ValueType)
    case invalidID(String)
    case duplicateID(firstPosition: Int)
    case emptyName
    case emptyIcon
    case unknownIcon(String)
    case unknownSort(String)
    case unknownKind(String)
    case noKinds
    case invalidQuery(SearchQueryError)

    public var message: String {
        switch self {
        case .notAnObject:
            "it is not an object with an id, a name and a query."
        case .unknownKeys(let keys):
            "unknown \(keys.count == 1 ? "key" : "keys") \(PresetTransfer.quoted(keys)). A preset takes \(PresetTransfer.quoted(PresetTransfer.Key.allCases.map(\.rawValue)))."
        case .missingKey(let key):
            "“\(key)” is missing."
        case .wrongType(let key, .string):
            "“\(key)” must be a string."
        case .wrongType(let key, .listOfStrings):
            "“\(key)” must be a list of strings."
        case .invalidID(let id):
            "“\(id)” is not a UUID. Generate one with uuidgen."
        case .duplicateID(let first):
            "it has the same id as preset \(first)."
        case .emptyName:
            "the name is empty."
        case .emptyIcon:
            "the icon is empty. Leave “icon” out for the default."
        case .unknownIcon(let icon):
            "“\(icon)” is not an SF Symbol."
        case .unknownSort(let sort):
            "unknown sort “\(sort)”. Use \(PresetTransfer.alternatives(SortOrder.allCases.map(\.rawValue)))."
        case .unknownKind(let kind):
            "unknown kind “\(kind)”. Use \(PresetTransfer.alternatives(ItemKind.allCases.map(\.rawValue)))."
        case .noKinds:
            "“kinds” is empty. List \(ItemKind.allCases.map(\.rawValue).joined(separator: ", ")) or both, or leave it out."
        case .invalidQuery(let error):
            "the query cannot be read. \(error.message)"
        }
    }
}

/// What pasting presets does to the existing list.
public struct PresetMerge: Equatable, Sendable {
    public var presets: [Preset]
    public var added: Int
    public var replaced: Int
    public var unchanged: Int

    public init(presets: [Preset], added: Int, replaced: Int, unchanged: Int) {
        self.presets = presets
        self.added = added
        self.replaced = replaced
        self.unchanged = unchanged
    }

    public var hasChanges: Bool { added + replaced > 0 }

    /// "2 new, 1 replaced", plus the unchanged ones when there are any.
    public var summary: String {
        var parts = ["\(added) new", "\(replaced) replaced"]
        if unchanged > 0 { parts.append("\(unchanged) unchanged") }
        return parts.joined(separator: ", ")
    }
}

/// Presets as portable JSON, for keeping them in a file outside the app and setting them up by copy and paste. The
/// format is a public contract; see `docs/adr/0013-presets-travel-as-json-with-stable-ids.md`.
///
/// ```json
/// { "version": 1, "presets": [ { "id": "6F0C2D6A-…", "name": "Mine", "query": "assignee:@me",
///                                "icon": "eye", "sort": "priority", "kinds": ["pullRequest", "issue"] } ] }
/// ```
///
/// A preset in the file is its query plus how it looks and sorts. Accounts, repositories, the structured filters,
/// notifications and the menu bar count stay in the app: the query carries the selection, and the rest is a
/// choice made on this Mac.
public enum PresetTransfer {
    public static let version = 1

    enum Key: String, CaseIterable {
        case id, name, query, icon, sort, kinds
    }

    private enum FileKey: String, CaseIterable {
        case version, presets
    }

    // MARK: Reading

    /// Reads the JSON that ``encode(_:)`` writes, or a bare list of presets. Everything is checked before anything is
    /// returned, so a paste either succeeds whole or changes nothing. Unknown keys are errors, so a typo is never
    /// dropped quietly.
    /// - Parameter iconExists: Whether an SF Symbol of that name exists. GitwallCore cannot ask AppKit, so the app
    ///   passes the check in; leave it out to accept any name.
    public static func decode(
        _ text: String,
        iconExists: (String) -> Bool = { _ in true }
    ) -> Result<[Preset], PresetTransferError> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.noText) }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            return .failure(.invalidJSON)
        }

        let entries: [JSONValue]
        switch json {
        case .array(let list):
            entries = list
        case .object(let file):
            let unknown = Set(file.keys).subtracting(FileKey.allCases.map(\.rawValue))
            guard unknown.isEmpty else { return .failure(.unknownKeys(unknown.sorted())) }
            guard let version = file[FileKey.version.rawValue] else { return .failure(.missingVersion) }
            guard version == .number(Double(Self.version)) else { return .failure(.unsupportedVersion(version.written)) }
            guard let presets = file[FileKey.presets.rawValue] else { return .failure(.missingPresets) }
            guard case .array(let list) = presets else { return .failure(.notAPresetFile) }
            entries = list
        default:
            return .failure(.notAPresetFile)
        }
        guard !entries.isEmpty else { return .failure(.noPresets) }
        return presets(from: entries, iconExists: iconExists)
            .mapError { .invalidPreset(position: $0.position, name: $0.name, problem: $0.problem) }
    }

    /// A preset in a list that cannot be read: its position from 1, the name it gives if any, and why.
    struct EntryError: Error {
        let position: Int
        let name: String?
        let problem: PresetProblem
    }

    /// Every entry of a list of presets, read and checked one by one, stopping at the first that fails. Used for the
    /// version 1 file and for the presets of a version 2 file alike.
    static func presets(from entries: [JSONValue], iconExists: (String) -> Bool) -> Result<[Preset], EntryError> {
        var presets: [Preset] = []
        var positions: [UUID: Int] = [:]
        for (offset, entry) in entries.enumerated() {
            let position = offset + 1
            switch preset(from: entry, iconExists: iconExists) {
            case .failure(let problem):
                return .failure(EntryError(position: position, name: usableName(of: entry), problem: problem))
            case .success(let preset):
                if let first = positions[preset.id] {
                    return .failure(EntryError(position: position, name: preset.name, problem: .duplicateID(firstPosition: first)))
                }
                positions[preset.id] = position
                presets.append(preset)
            }
        }
        return .success(presets)
    }

    static func preset(from entry: JSONValue, iconExists: (String) -> Bool) -> Result<Preset, PresetProblem> {
        guard case .object(let fields) = entry else { return .failure(.notAnObject) }
        let unknown = Set(fields.keys).subtracting(Key.allCases.map(\.rawValue))
        guard unknown.isEmpty else { return .failure(.unknownKeys(unknown.sorted())) }

        func string(_ key: Key) -> Result<String?, PresetProblem> {
            switch fields[key.rawValue] {
            case nil: .success(nil)
            case .string(let value)?: .success(value)
            default: .failure(.wrongType(key: key.rawValue, expected: .string))
            }
        }
        func required(_ key: Key) -> Result<String, PresetProblem> {
            switch string(key) {
            case .success(let value?): .success(value)
            case .success(nil): .failure(.missingKey(key.rawValue))
            case .failure(let problem): .failure(problem)
            }
        }

        do throws(PresetProblem) {
            let rawID = try required(.id).get()
            guard let id = UUID(uuidString: rawID) else { return .failure(.invalidID(rawID)) }

            let name = try required(.name).get()
            guard !isBlank(name) else { return .failure(.emptyName) }

            let query = try required(.query).get()
            if case .failure(let error) = SearchQuery.parse(query) { return .failure(.invalidQuery(error)) }

            let icon = try string(.icon).get() ?? Preset.defaultIcon
            guard !isBlank(icon) else { return .failure(.emptyIcon) }
            guard iconExists(icon) else { return .failure(.unknownIcon(icon)) }

            var sort = SortOrder.lastActivity
            if let rawSort = try string(.sort).get() {
                guard let value = SortOrder(rawValue: rawSort) else { return .failure(.unknownSort(rawSort)) }
                sort = value
            }

            var kinds = Set(ItemKind.allCases)
            if let rawKinds = fields[Key.kinds.rawValue] {
                guard case .array(let list) = rawKinds else {
                    return .failure(.wrongType(key: Key.kinds.rawValue, expected: .listOfStrings))
                }
                kinds = []
                for value in list {
                    guard case .string(let rawKind) = value else {
                        return .failure(.wrongType(key: Key.kinds.rawValue, expected: .listOfStrings))
                    }
                    guard let kind = ItemKind(rawValue: rawKind) else { return .failure(.unknownKind(rawKind)) }
                    kinds.insert(kind)
                }
                guard !kinds.isEmpty else { return .failure(.noKinds) }
            }

            return .success(Preset(id: id, name: name, icon: icon, kinds: kinds, filter: filter(query: query), sort: sort))
        } catch {
            return .failure(error)
        }
    }

    /// The name for the error message, when the preset has one worth showing.
    static func usableName(of entry: JSONValue) -> String? {
        guard case .object(let fields) = entry, case .string(let name)? = fields[Key.name.rawValue], !isBlank(name) else {
            return nil
        }
        return name
    }

    /// A blank query means every item, as the preset editor stores it.
    private static func filter(query: String?) -> ItemFilter {
        guard let query, !isBlank(query) else { return ItemFilter() }
        return ItemFilter(query: query)
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Writing

    /// Pretty-printed with sorted keys, so the file diffs cleanly. Always writes every key of every preset, so
    /// reading it back gives exactly the same presets.
    public static func encode(_ presets: [Preset]) -> String {
        let file = File(
            version: version,
            presets: presets.map(Entry.init)
        )
        guard let data = try? SnapshotCoding.encode(file) else {
            preconditionFailure("Presets of strings and UUIDs could not be encoded")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private struct File: Encodable {
        let version: Int
        let presets: [Entry]
    }

    /// One preset as the file writes it; also the presets of a Gitwall file (``GitwallFile``).
    struct Entry: Encodable {
        let id: UUID
        let name: String
        let query: String
        let icon: String
        let sort: SortOrder
        let kinds: [ItemKind]

        init(_ preset: Preset) {
            id = preset.id
            name = preset.name
            query = preset.filter.query ?? ""
            icon = preset.icon
            sort = preset.sort
            kinds = ItemKind.allCases.filter(preset.kinds.contains)
        }
    }

    /// What ``encode(_:)`` leaves out of `presets` that changes which items they show, or nil when nothing. Notifications
    /// and the menu bar count are left out too, but they do not change the selection and pasting keeps them.
    public static func copyWarning(for presets: [Preset]) -> String? {
        let lossy: [String] = presets.compactMap { preset in
            var lost: [String] = []
            if !preset.scopes.isEmpty { lost.append("accounts and repositories") }
            var structured = preset.filter
            structured.query = nil
            if structured != ItemFilter() { lost.append("filters outside the query") }
            return lost.isEmpty ? nil : "“\(preset.name)” (\(lost.joined(separator: ", ")))"
        }
        guard !lossy.isEmpty else { return nil }

        let shown = 5
        var list = lossy.prefix(shown).joined(separator: ", ")
        if lossy.count > shown { list += " and \(lossy.count - shown) more" }
        return "The JSON carries only the name, icon, sort, kinds and query of a preset. Left out: \(list)."
    }

    // MARK: Merging

    /// Pasting: a preset whose id is already here gets the pasted name, icon, sort, kinds and query, and loses its
    /// structured filters, because a pasted preset is defined by its query alone; its accounts, notifications and menu
    /// bar count stay as the user set them. A new id is appended. Nothing is ever removed.
    public static func merge(_ incoming: [Preset], into existing: [Preset]) -> PresetMerge {
        var result = PresetMerge(presets: existing, added: 0, replaced: 0, unchanged: 0)
        for preset in incoming {
            if let index = result.presets.firstIndex(where: { $0.id == preset.id }) {
                var updated = result.presets[index]
                updated.name = preset.name
                updated.icon = preset.icon
                updated.sort = preset.sort
                updated.kinds = preset.kinds
                updated.filter = filter(query: preset.filter.query)
                if updated == result.presets[index] {
                    result.unchanged += 1
                } else {
                    result.presets[index] = updated
                    result.replaced += 1
                }
            } else {
                result.presets.append(Preset(
                    id: preset.id,
                    name: preset.name,
                    icon: preset.icon,
                    kinds: preset.kinds,
                    filter: filter(query: preset.filter.query),
                    sort: preset.sort
                ))
                result.added += 1
            }
        }
        return result
    }

    // MARK: Text helpers

    /// “a”, “b”
    static func quoted(_ values: [String]) -> String {
        values.map { "“\($0)”" }.joined(separator: ", ")
    }

    /// a, b or c
    static func alternatives(_ values: [String]) -> String {
        guard let last = values.last, values.count > 1 else { return values.first ?? "" }
        return values.dropLast().joined(separator: ", ") + " or " + last
    }
}

/// Any JSON value, so the paste can name unknown keys and wrong types itself instead of passing on a
/// `DecodingError`.
enum JSONValue: Decodable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// Roughly as it was written, for an error message.
    var written: String {
        switch self {
        case .number(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .string(let value): "\"\(value)\""
        case .bool(let value): String(value)
        case .null: "null"
        case .array: "a list"
        case .object: "an object"
        }
    }
}
