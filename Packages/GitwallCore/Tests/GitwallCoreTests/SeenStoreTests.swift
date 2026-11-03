import Foundation
import Testing
@testable import GitwallCore

@Suite("SeenStore")
struct SeenStoreTests {
    typealias S = DetailSupport

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gitwall-seen-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("nothing seen before anything is written")
    func empty() async {
        let store = SeenStore(directoryURL: makeDirectory())
        #expect(await store.load().isEmpty)
    }

    @Test("marking an item seen survives a new store on the same file")
    func persists() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SeenStore(directoryURL: directory)
        let entries = try await first.markSeen("a", at: S.now, keeping: ["a"])
        #expect(entries == ["a": S.now])

        let second = SeenStore(directoryURL: directory)
        #expect(await second.load() == ["a": S.now])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("seen.json").path))
    }

    @Test("marking again moves the time forward")
    func updates() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SeenStore(directoryURL: directory)

        _ = try await store.markSeen("a", at: S.at(minutes: -10), keeping: ["a"])
        let entries = try await store.markSeen("a", at: S.now, keeping: ["a"])

        #expect(entries == ["a": S.now])
    }

    @Test("an entry stays while its item is in the snapshot or was seen in the last 30 days")
    func pruning() {
        let day: TimeInterval = 86_400
        let entries: [String: Date] = [
            "live-old": S.now.addingTimeInterval(-90 * day),
            "gone-recent": S.now.addingTimeInterval(-29 * day),
            "gone-old": S.now.addingTimeInterval(-31 * day),
        ]

        let kept = SeenStore.pruned(entries, keeping: ["live-old"], now: S.now)

        #expect(Set(kept.keys) == ["live-old", "gone-recent"])
    }

    @Test("writing prunes what the snapshot no longer has")
    func writePrunes() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SeenStore(directoryURL: directory)
        _ = try await store.markSeen("old", at: S.now.addingTimeInterval(-40 * 86_400), keeping: ["old"])

        let entries = try await store.markSeen("new", at: S.now, keeping: ["new"])

        #expect(entries == ["new": S.now])
        #expect(await SeenStore(directoryURL: directory).load() == ["new": S.now])
    }

    @Test("an unreadable file counts as nothing seen and is replaced by the next write")
    func corruptFile() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("seen.json"))
        let store = SeenStore(directoryURL: directory)

        #expect(await store.load().isEmpty)
        _ = try await store.markSeen("a", at: S.now, keeping: ["a"])
        #expect(await SeenStore(directoryURL: directory).load() == ["a": S.now])
    }
}
