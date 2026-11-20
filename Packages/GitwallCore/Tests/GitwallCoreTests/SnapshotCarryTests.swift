import Foundation
import Testing
@testable import GitwallCore

@Suite("What the app keeps after a sync or a fetch on open")
struct SnapshotCarryTests {
    let account = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ number: Int) -> WorkItem {
        WorkItem(accountID: account, kind: .pullRequest, repoFullName: "acme/app", number: number, title: "PR \(number)",
                 url: URL(string: "https://example.com/\(number)")!, author: UserRef(login: "alice"),
                 createdAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-60))
    }

    func snapshot(_ numbers: [Int], at offset: TimeInterval = 0) -> Snapshot {
        Snapshot(fetchedAt: now.addingTimeInterval(offset), items: numbers.map(item))
    }

    func ids(_ numbers: [Int]) -> Set<String> { Set(numbers.map { item($0).id }) }

    @Test("A sync replaces the dots and the previous snapshot")
    func syncReplaces() {
        let kept = SnapshotCarry.kept(
            after: .sync, current: snapshot([1, 2, 3]), replaced: snapshot([1, 2], at: -60), newItemIDs: ids([3]),
            earlierPrevious: snapshot([1, 2, 9], at: -120), earlierNewItemIDs: ids([2])
        )
        #expect(kept.newItemIDs == ids([3]))
        #expect(kept.previous == snapshot([1, 2], at: -60))
    }

    @Test("A fetch on open adds its dots to the ones not yet seen")
    func fetchUnionsDots() {
        let kept = SnapshotCarry.kept(
            after: .fetchOnOpen, current: snapshot([1, 2, 3, 4]), replaced: snapshot([1, 2, 3]), newItemIDs: ids([4]),
            earlierPrevious: nil, earlierNewItemIDs: ids([2, 3])
        )
        #expect(kept.newItemIDs == ids([2, 3, 4]))
    }

    @Test("A dot for an item that is no longer in the snapshot is dropped")
    func goneDotIsDropped() {
        let kept = SnapshotCarry.kept(
            after: .fetchOnOpen, current: snapshot([1, 3]), replaced: snapshot([1, 2, 3]), newItemIDs: [],
            earlierPrevious: nil, earlierNewItemIDs: ids([2, 3])
        )
        #expect(kept.newItemIDs == ids([3]))
    }

    @Test("A fetch on open keeps the closed item only the earlier previous snapshot held, and gains the new ones")
    func fetchMergesPrevious() throws {
        let replaced = snapshot([1, 2, 5], at: -60)
        let kept = SnapshotCarry.kept(
            after: .fetchOnOpen, current: snapshot([1, 2, 5, 6], at: 0), replaced: replaced, newItemIDs: ids([6]),
            earlierPrevious: snapshot([1, 2, 7], at: -120), earlierNewItemIDs: []
        )
        let previous = try #require(kept.previous)
        #expect(Set(previous.items.map(\.id)) == ids([1, 2, 5, 7]))
        #expect(previous.fetchedAt == replaced.fetchedAt)
    }

    @Test("Without an earlier previous snapshot a fetch on open keeps the one it replaced")
    func fetchWithoutEarlierPrevious() {
        let replaced = snapshot([1, 2], at: -60)
        let kept = SnapshotCarry.kept(
            after: .fetchOnOpen, current: snapshot([1, 2, 3]), replaced: replaced, newItemIDs: ids([3]),
            earlierPrevious: nil, earlierNewItemIDs: []
        )
        #expect(kept.previous == replaced)
    }

    @Test("Nothing replaced leaves the earlier previous snapshot as it is")
    func fetchWithoutReplaced() {
        let earlier = snapshot([1, 9], at: -120)
        let kept = SnapshotCarry.kept(
            after: .fetchOnOpen, current: snapshot([1]), replaced: nil, newItemIDs: [],
            earlierPrevious: earlier, earlierNewItemIDs: []
        )
        #expect(kept.previous == earlier)
    }
}
