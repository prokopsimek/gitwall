import CryptoKit
import Foundation

extension Preset {
    /// A fingerprint of exactly what selects the preset's items: ``filter`` (with its ``ItemFilter/query``), ``kinds``,
    /// ``scopes`` and ``sort``. Name, icon, notifications and the menu bar count leave it as it is. A
    /// ``PresetResult`` stores the fingerprint it was fetched for, so an edited selection shows as never fetched.
    ///
    /// The same selection gives the same fingerprint in every launch. A set iterates in an order seeded per process
    /// and per hash table, so its plain encoding differs from launch to launch, sorted keys or not. The selection is
    /// therefore encoded to JSON first and then written out again with every object's keys sorted and every list
    /// sorted. Sorting lists is sound because no list in a selection depends on its order: scopes, labels and logins
    /// match in any order. A list whose order changes what it selects would need its own case here. A field added to
    /// ``ItemFilter`` is part of its encoding, and so of the fingerprint, without a change here.
    ///
    /// The canonical text goes through SHA-256: the hex digest keeps every stored result the same small size whatever
    /// the query and lists hold, and nothing ever reads a fingerprint back, it is only compared.
    public var selectionFingerprint: String {
        let selection = Selection(filter: filter, kinds: kinds, scopes: scopes, sort: sort)
        let canonical: String
        do {
            let encoded = try JSONEncoder().encode(selection)
            canonical = try JSONDecoder().decode(CanonicalJSON.self, from: encoded).text
        } catch {
            preconditionFailure("A preset selection of strings, numbers and flags could not be encoded: \(error)")
        }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The parts of a preset that select its items, in the shape they are encoded in.
private struct Selection: Encodable {
    let filter: ItemFilter
    let kinds: Set<ItemKind>
    let scopes: [PresetScope]
    let sort: SortOrder
}

/// Any JSON value, read back from an encoding so it can be written out again in one form.
private enum CanonicalJSON: Decodable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([CanonicalJSON])
    case object([String: CanonicalJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CanonicalJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CanonicalJSON].self))
        }
    }

    /// JSON text with the keys of every object in order and every array sorted by the text of its elements.
    var text: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .string(let value): Self.quoted(value)
        case .array(let elements): "[" + elements.map(\.text).sorted().joined(separator: ",") + "]"
        case .object(let members):
            "{" + members.sorted { $0.key < $1.key }.map { Self.quoted($0.key) + ":" + $0.value.text }
                .joined(separator: ",") + "}"
        }
    }

    /// A JSON string literal, so a quote or comma inside a label cannot run into the next element.
    private static func quoted(_ string: String) -> String {
        var quoted = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case _ where scalar.value < 0x20: quoted += String(format: "\\u%04x", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}
