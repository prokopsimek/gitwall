import Foundation

/// Persists `AppConfig` as `config.json` in a directory (the App Group container in production).
public struct ConfigStore: Sendable {
    public static let fileName = "config.json"

    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }

    /// Returns `.empty` when no configuration has been written yet.
    public func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        return try SnapshotCoding.decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try SnapshotCoding.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}
