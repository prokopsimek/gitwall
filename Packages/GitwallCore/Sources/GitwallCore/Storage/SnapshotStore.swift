import Foundation

/// Persists the current and previous snapshot as JSON files in a directory (the App Group container in production).
public struct SnapshotStore: Sendable {
    public static let currentFileName = "snapshot.json"
    public static let previousFileName = "snapshot.previous.json"

    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var currentURL: URL { directoryURL.appendingPathComponent(Self.currentFileName) }
    public var previousURL: URL { directoryURL.appendingPathComponent(Self.previousFileName) }

    public func load() throws -> Snapshot? {
        try read(currentURL)
    }

    public func loadPrevious() throws -> Snapshot? {
        try read(previousURL)
    }

    /// Writes `snapshot` as the current one and keeps the former current snapshot as previous.
    public func save(_ snapshot: Snapshot) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let data = try SnapshotCoding.encode(snapshot)
        let staging = directoryURL.appendingPathComponent(".\(Self.currentFileName).\(UUID().uuidString).tmp")
        try data.write(to: staging, options: .atomic)

        if fm.fileExists(atPath: currentURL.path) {
            _ = try fm.replaceItemAt(previousURL, withItemAt: currentURL)
        }
        _ = try fm.replaceItemAt(currentURL, withItemAt: staging)
    }

    private func read(_ url: URL) throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try SnapshotCoding.decode(Snapshot.self, from: data)
    }
}
