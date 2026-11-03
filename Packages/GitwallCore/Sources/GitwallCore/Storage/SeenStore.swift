import Foundation

/// When the signed-in account last opened each item in Detail: `seen.json` in a directory (the App Group container
/// in production), next to the snapshot. "What's new" and the dot in lists compare against it. The widget never
/// reads it. Sample data must not reach it; the app keeps those times in memory.
public actor SeenStore {
    public static let fileName = "seen.json"
    /// An item no longer in the snapshot is forgotten this long after it was last opened.
    public static let retention: TimeInterval = 30 * 86_400

    private struct File: Codable {
        var version = 1
        var items: [String: Date]
    }

    public let fileURL: URL
    private var entries: [String: Date]?

    public init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent(Self.fileName)
    }

    /// ``WorkItem/id`` → last opened. A missing or unreadable file is nothing seen; the next write replaces it.
    public func load() -> [String: Date] {
        if let entries { return entries }
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? SnapshotCoding.decode(File.self, from: $0).items } ?? [:]
        entries = loaded
        return loaded
    }

    /// Records the open and prunes to `liveItemIDs` (the items of the current snapshot) plus the last
    /// ``retention``. Returns every entry after the write.
    @discardableResult
    public func markSeen(_ itemID: String, at date: Date, keeping liveItemIDs: Set<String>) throws -> [String: Date] {
        var updated = load()
        updated[itemID] = date
        updated = Self.pruned(updated, keeping: liveItemIDs.union([itemID]), now: date)
        try write(updated)
        entries = updated
        return updated
    }

    public static func pruned(_ entries: [String: Date], keeping liveItemIDs: Set<String>, now: Date) -> [String: Date] {
        let cutoff = now.addingTimeInterval(-retention)
        return entries.filter { liveItemIDs.contains($0.key) || $0.value >= cutoff }
    }

    private func write(_ entries: [String: Date]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SnapshotCoding.encode(File(items: entries)).write(to: fileURL, options: .atomic)
    }
}
