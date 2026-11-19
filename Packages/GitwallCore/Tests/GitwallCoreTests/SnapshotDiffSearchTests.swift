import Foundation
import Testing
@testable import GitwallCore

/// What a sync that searched presets on GitHub.com reports. A search returns only open items that match, so for an
/// account that searched, a missing item counts only when it was confirmed closed or merged, and a new one only when a
/// result that had an earlier result to compare with brought it.
@Suite("SnapshotDiff with preset searches")
struct SnapshotDiffSearchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let github = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub", me: UserRef(login: "me"))
    let gitlab = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, displayName: "GitLab", me: UserRef(login: "me"))
    let enterprise = Account(kind: .github, baseURL: URL(string: "https://github.acme.test")!, displayName: "Acme",
                             me: UserRef(login: "me"))

    /// - Parameter created: When the item was opened; `now`, the moment the previous snapshot was fetched, by default.
    private func item(
        _ number: Int, in account: Account? = nil, review: ReviewState = .none, ci: CIState = .none,
        labels: [String] = [], requested: [String] = [], created: Date? = nil
    ) -> WorkItem {
        WorkItem(accountID: (account ?? github).id, kind: .pullRequest, repoFullName: "acme/app", number: number,
                 title: "Item \(number)", url: URL(string: "https://example.com/\(number)")!, author: UserRef(login: "x"),
                 createdAt: created ?? now, updatedAt: now, labels: labels.map { Label(name: $0) }, reviewState: review,
                 ciState: ci, requestedReviewers: requested.map { UserRef(login: $0) })
    }

    /// A moment that long before `now`, when the previous snapshot was fetched.
    private func before(days: Double = 0, minutes: Double = 0) -> Date {
        now.addingTimeInterval(-(days * 86_400 + minutes * 60))
    }

    /// A sync in which the GitHub.com account searched presets.
    private func searched(closed: [WorkItem] = [], compared: [WorkItem] = []) -> SearchFindings {
        SearchFindings(accounts: [github.id], closedItemIDs: Set(closed.map(\.id)), comparedItemIDs: Set(compared.map(\.id)))
    }

    /// A sync in which the GitHub.com account searched presets and each item of `compared` was compared with an
    /// earlier result fetched at the date given for it.
    private func searched(comparedSince dates: [(WorkItem, Date)]) -> SearchFindings {
        SearchFindings(accounts: [github.id], closedItemIDs: [],
                       comparedSince: Dictionary(uniqueKeysWithValues: dates.map { ($0.0.id, $0.1) }))
    }

    /// - Parameter previousSearched: The accounts that searched presets in the sync that wrote the previous snapshot.
    private func events(
        _ previous: [WorkItem], _ current: [WorkItem], _ searches: SearchFindings,
        previousResults: [PresetResult] = [], currentResults: [PresetResult] = [], previousSearched: Set<UUID> = []
    ) -> [Int: [NotificationEvent]] {
        let changes = SnapshotDiff.changes(
            from: Snapshot(fetchedAt: now, items: previous, presetResults: previousResults, searchedAccounts: previousSearched),
            to: Snapshot(fetchedAt: now, items: current, presetResults: currentResults),
            accounts: [github, gitlab, enterprise], searches: searches
        )
        return Dictionary(grouping: changes, by: { $0.item.number }).mapValues { $0.map(\.event).sorted { $0.rawValue < $1.rawValue } }
    }

    @Test("an item of a searched account confirmed closed or merged is reported closed, once")
    func confirmedClosed() {
        let gone = item(2)
        #expect(events([item(1), gone], [item(1)], searched(closed: [gone])) == [2: [.closed]])
    }

    @Test("an item of a searched account that left without being confirmed closed sends nothing")
    func unconfirmedMissing() {
        #expect(events([item(1), item(2)], [item(1)], searched()).isEmpty)
    }

    @Test("an item that came with the first result of its pair is no new item, not even with a review request for me")
    func firstResultIsABaseline() {
        #expect(events([item(1)], [item(1), item(2, requested: ["me"])], searched()).isEmpty)
    }

    @Test("a new item in a result that had an earlier result to compare with is new, with its review request")
    func newInAComparedResult() {
        let new = item(2, requested: ["me"])
        #expect(events([item(1)], [item(1), new], searched(compared: [new])) == [2: [.newItem, .reviewRequested]])
    }

    @Test("an old item that enters a compared result because my review was requested reports only the review request")
    func oldItemWithAReviewRequest() {
        // Opened three months before the previous sync; the request is what brought it into the search.
        let old = item(2, requested: ["me"], created: before(days: 90))
        #expect(events([item(1)], [item(1), old], searched(compared: [old])) == [2: [.reviewRequested]])
    }

    @Test("an old item that enters a compared result without asking me, by a label or recent activity, sends nothing")
    func oldItemThatStartedToMatch() {
        let old = item(2, labels: ["urgent"], created: before(days: 90))
        #expect(events([item(1)], [item(1), old], searched(compared: [old])).isEmpty)
    }

    @Test("an item opened up to ten minutes before the previous sync is still new, because GitHub's search index can lag")
    func searchIndexLag() {
        let late = item(2, created: before(minutes: 5))
        let older = item(3, created: before(minutes: 11))
        #expect(events([item(1)], [item(1), late, older], searched(compared: [late, older])) == [2: [.newItem]])
    }

    @Test("an item opened after the previous sync in a compared result is new, with its review request")
    func openedSinceThePreviousSync() {
        let fresh = item(2, requested: ["me"], created: now.addingTimeInterval(5 * 60))
        #expect(events([item(1)], [item(1), fresh], searched(compared: [fresh])) == [2: [.newItem, .reviewRequested]])
    }

    @Test("an old item new to the snapshot of an account that downloads everything is still a new item")
    func oldItemOfAnAccountThatDownloadsEverything() {
        let current = [item(4, in: gitlab, created: before(days: 90)),
                       item(5, in: enterprise, requested: ["me"], created: before(days: 90))]
        #expect(events([], current, searched()) == [4: [.newItem], 5: [.newItem, .reviewRequested]])
        #expect(events([], [item(6, created: before(days: 90))], .none) == [6: [.newItem]])
    }

    @Test("an item opened after the earlier result of its pair but before the previous sync is a new item")
    func openedAfterThePairsEarlierResult() {
        let new = item(2, requested: ["me"], created: before(days: 1))
        let findings = searched(comparedSince: [(new, before(days: 3))])
        #expect(events([item(1)], [item(1), new], findings) == [2: [.newItem, .reviewRequested]])
    }

    @Test("an item opened before the earlier result of its pair, less the index lag, is no new item")
    func openedBeforeThePairsEarlierResult() {
        let old = item(2, requested: ["me"], created: before(days: 4))
        let late = item(3, created: before(days: 3, minutes: 5))
        let findings = searched(comparedSince: [(old, before(days: 3)), (late, before(days: 3))])
        #expect(events([item(1)], [item(1), old, late], findings) == [2: [.reviewRequested], 3: [.newItem]])
    }

    @Test("an item two pairs compared is judged by the older of their dates")
    func theOlderDateWins() {
        let new = item(2, created: before(days: 2))
        var findings = searched(comparedSince: [(new, before(days: 1))])
        #expect(events([item(1)], [item(1), new], findings).isEmpty)
        findings.merge(compared: [new.id: before(days: 3)])
        findings.merge(compared: [new.id: before(days: 1)])
        #expect(events([item(1)], [item(1), new], findings) == [2: [.newItem]])
    }

    @Test("a compared item without a date of its own is judged by the previous sync")
    func fallsBackToThePreviousSync() {
        let new = item(2, created: before(days: 1))
        #expect(searched(compared: [new]).comparedItemIDs == [new.id])
        #expect(events([item(1)], [item(1), new], searched(compared: [new])).isEmpty)
    }

    @Test("an item in both snapshots of a searched account gets today's events: a review changes, a label does not")
    func changesOfKeptItems() {
        let previous = [item(1), item(2, labels: ["a"]), item(3, ci: .running)]
        let current = [item(1, review: .approved), item(2, labels: ["b"]), item(3, ci: .failure)]
        #expect(events(previous, current, searched()) == [1: [.approved], 3: [.ciFailed]])
    }

    @Test("an item two results hold changes once")
    func twoResultsOneEvent() {
        let gone = item(2), new = item(3)
        let results = [UUID(), UUID()].map {
            PresetResult(presetID: $0, accountID: github.id, itemIDs: [gone.id, new.id], fetchedAt: now, totalCount: 2,
                         isComplete: true, selection: "s")
        }
        #expect(events([item(1), gone], [item(1), new], searched(closed: [gone], compared: [new]),
                       previousResults: results, currentResults: results)
            == [2: [.closed], 3: [.newItem]])
    }

    @Test("items of GitLab and GitHub Enterprise accounts keep today's rules in a sync that searched GitHub.com")
    func otherAccountsUnchanged() {
        let previous = [item(1, in: gitlab), item(2, in: enterprise), item(3)]
        let current = [item(4, in: gitlab), item(5, in: enterprise, requested: ["me"])]
        #expect(events(previous, current, searched())
            == [1: [.closed], 2: [.closed], 4: [.newItem], 5: [.newItem, .reviewRequested]])
    }

    @Test("the first sync with a selection after the update sends nothing for the searched account")
    func firstSyncAfterTheUpdate() {
        // The previous snapshot holds no preset results: every item of it came from a full fetch.
        let previous = [item(1), item(2), item(3, requested: ["me"])]
        let current = [item(3, requested: ["me"]), item(4), item(5, requested: ["me"])]
        let results = [PresetResult(presetID: UUID(), accountID: github.id, itemIDs: current.map(\.id), fetchedAt: now,
                                    totalCount: 3, isComplete: true, selection: "s")]
        #expect(events(previous, current, searched(), currentResults: results).isEmpty)
    }

    @Test("the first full download after an account searched brings nothing new and closes nothing; its kept items and other accounts count as always")
    func fullDownloadAfterSearch() {
        // The previous snapshot held what the searches found, up to 1000 per preset; the full download has the open
        // items it reaches. An item in one and not the other may be new, closed or merely out of the other's reach.
        let previous = [item(1), item(6), item(3, in: gitlab), item(7, in: gitlab)]
        let current = [item(1, review: .approved), item(2, requested: ["me"]), item(3, in: gitlab), item(4, in: gitlab)]
        #expect(events(previous, current, .none, previousSearched: [github.id])
            == [1: [.approved], 4: [.newItem], 7: [.closed]])
    }
}
