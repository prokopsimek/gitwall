import Foundation
import Testing
@testable import GitwallCore

@Suite("Reading a preset's result")
struct PresetResultReadingTests {
    /// Two accounts that search each preset, and one that fetches everything.
    let work = UUID()
    let personal = UUID()
    let gitlab = UUID()

    let review = Preset(name: "Waiting for my review", filter: ItemFilter(relations: [.reviewRequestedFromMe]))
    let blockers = Preset(name: "Release blockers", kinds: [.issue], filter: ItemFilter(labelsAny: ["blocker"]))
    let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ number: Int, _ account: UUID) -> WorkItem {
        WorkItem(accountID: account, kind: .pullRequest, repoFullName: "acme/app", number: number, title: "PR \(number)",
                 url: URL(string: "https://example.com/\(number)")!, author: UserRef(login: "bob"),
                 createdAt: fetchedAt, updatedAt: fetchedAt.addingTimeInterval(-Double(number)))
    }

    func result(_ preset: Preset, _ account: UUID, _ items: [WorkItem]) -> PresetResult {
        PresetResult(presetID: preset.id, accountID: account, itemIDs: items.map(\.id), fetchedAt: fetchedAt,
                     totalCount: items.count, isComplete: true, selection: preset.selectionFingerprint)
    }

    @Test("a preset reads its own result for each account")
    func readsOwnResult() {
        let reviewAtWork = result(review, work, [item(1, work)])
        let reviewPersonal = result(review, personal, [item(2, personal)])
        let snapshot = Snapshot(fetchedAt: fetchedAt, items: [], presetResults: [
            reviewAtWork, result(blockers, work, [item(3, work)]), reviewPersonal,
        ])

        #expect(snapshot.result(for: review, account: work) == reviewAtWork)
        #expect(snapshot.result(for: review, account: personal) == reviewPersonal)
        #expect(snapshot.result(for: blockers, account: personal) == nil)
    }

    @Test("a result fetched for another selection of the preset reads as never fetched")
    func otherSelectionReadsAsNeverFetched() {
        let snapshot = Snapshot(fetchedAt: fetchedAt, items: [item(1, work)],
                                presetResults: [result(review, work, [item(1, work)])])
        var edited = review
        edited.filter.relations = [.assignedToMe]

        #expect(snapshot.result(for: edited, account: work) == nil)
        #expect(snapshot.items(for: edited, searchedAccounts: [work]).isEmpty)
    }

    @Test("a searched account gives only the items of the preset's result; any other account gives all of its items")
    func itemsOfPreset() {
        let items = [item(1, work), item(2, work), item(3, work), item(4, gitlab), item(5, gitlab), item(6, personal)]
        let snapshot = Snapshot(fetchedAt: fetchedAt, items: items, presetResults: [
            result(review, work, [item(3, work), item(1, work)]),
            result(blockers, work, [item(2, work)]),
            result(review, personal, [item(6, personal)]),
        ])

        #expect(snapshot.items(for: review, searchedAccounts: [work, personal]).map(\.number) == [1, 3, 4, 5, 6])
        #expect(snapshot.items(for: blockers, searchedAccounts: [work, personal]).map(\.number) == [2, 4, 5])
    }

    @Test("a searched account without a result for the preset gives none of its items")
    func searchedAccountWithoutResult() {
        let snapshot = Snapshot(fetchedAt: fetchedAt, items: [item(1, work), item(2, gitlab)], presetResults: [])

        #expect(snapshot.items(for: review, searchedAccounts: [work]).map(\.number) == [2])
    }

    @Test("without searched accounts a preset gives every item, as before preset results")
    func noSearchedAccounts() {
        let items = [item(1, work), item(2, gitlab)]
        let snapshot = Snapshot(fetchedAt: fetchedAt, items: items, presetResults: [result(review, work, [])])

        #expect(snapshot.items(for: review, searchedAccounts: []) == items)
    }
}
