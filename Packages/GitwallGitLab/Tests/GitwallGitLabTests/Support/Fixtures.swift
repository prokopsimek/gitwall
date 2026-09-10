import Foundation

enum Fixtures {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "Missing fixture \(name)" }
    }

    static func url(_ name: String) throws -> URL {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = Bundle.module.url(
            forResource: parts[0],
            withExtension: parts.count > 1 ? parts[1] : nil,
            subdirectory: "Fixtures"
        ) else { throw Missing(name: name) }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}
