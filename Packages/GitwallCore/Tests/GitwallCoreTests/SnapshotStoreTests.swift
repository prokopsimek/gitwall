import Foundation
import Testing
@testable import GitwallCore

@Suite("SnapshotStore")
struct SnapshotStoreTests {
    private func makeStore() throws -> (SnapshotStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitwall-tests-\(UUID().uuidString)", isDirectory: true)
        return (SnapshotStore(directoryURL: dir), dir)
    }

    @Test("returns nil when nothing has been written yet")
    func emptyRead() throws {
        let (store, _) = try makeStore()
        #expect(try store.load() == nil)
    }

    @Test("writes a snapshot and reads it back")
    func writeThenRead() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: Fixtures.data("snapshot.json"))

        try store.save(snapshot)

        #expect(try store.load() == snapshot)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("snapshot.json").path))
    }

    @Test("saving keeps the previous snapshot for diffing")
    func keepsPrevious() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try SnapshotCoding.decode(Snapshot.self, from: Fixtures.data("snapshot.json"))
        var second = first
        second.fetchedAt = first.fetchedAt.addingTimeInterval(300)
        second.items.removeLast()

        try store.save(first)
        try store.save(second)

        #expect(try store.load() == second)
        #expect(try store.loadPrevious() == first)
    }

    @Test("previous is nil after the very first save")
    func noPreviousInitially() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: Fixtures.data("snapshot.json"))

        try store.save(snapshot)

        #expect(try store.loadPrevious() == nil)
    }
}
