import Foundation
import Testing
@testable import GitwallCore

@Suite("Preset freshness")
struct PresetFreshnessTests {
    /// GitHub goes by preset results; GitLab fetches every item with each sync.
    let github = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub",
                         me: UserRef(login: "bob"))
    let gitlab = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, displayName: "GitLab",
                         me: UserRef(login: "bob"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// The sync interval, five minutes as by default.
    let interval: TimeInterval = 300
    /// Items labelled docs on every account: a GitHub part that searches and a GitLab part that fetches everything.
    let docs: Preset
    let githubDocs: Preset
    let gitlabDocs: Preset

    init() {
        let filter = ItemFilter(labelsAny: ["docs"])
        docs = Preset(name: "Docs", filter: filter)
        githubDocs = Preset(name: "GitHub docs", scopes: [PresetScope(accountID: github.id)], filter: filter)
        gitlabDocs = Preset(name: "GitLab docs", scopes: [PresetScope(accountID: gitlab.id)], filter: filter)
    }

    var accounts: [Account] { [github, gitlab] }

    func minutes(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    /// Item `number` was last active `number` minutes ago, so a lower number sorts first by last activity.
    func item(_ number: Int, _ account: Account, labels: [String] = ["docs"]) -> WorkItem {
        WorkItem(accountID: account.id, kind: .pullRequest, repoFullName: "acme/app", number: number, title: "PR \(number)",
                 url: URL(string: "https://example.com/\(number)")!, author: UserRef(login: "alice"),
                 createdAt: minutes(-60), updatedAt: minutes(-Double(number)), labels: labels.map { Label(name: $0) })
    }

    /// The result of `preset` in the GitHub account.
    func result(
        _ preset: Preset, holding items: [WorkItem], fetchedAt: Date?, totalCount: Int? = nil, isComplete: Bool = true,
        failure: PresetQueryFailure? = nil
    ) -> PresetResult {
        PresetResult(presetID: preset.id, accountID: github.id, itemIDs: items.map(\.id), fetchedAt: fetchedAt,
                     totalCount: totalCount ?? items.count, isComplete: isComplete, selection: preset.selectionFingerprint,
                     failure: failure)
    }

    /// A snapshot in which GitHub searched presets and synced a minute ago, and GitLab synced at `gitlabSyncedAt`, or
    /// never when it is nil.
    func snapshot(
        _ items: [WorkItem], results: [PresetResult] = [], gitlabSyncedAt: Date? = nil,
        searchedAccounts: Set<UUID>? = nil
    ) -> Snapshot {
        var status = [github.id: FetchStatus(state: .ok, lastSuccessAt: minutes(-1))]
        if let gitlabSyncedAt { status[gitlab.id] = FetchStatus(state: .ok, lastSuccessAt: gitlabSyncedAt) }
        return Snapshot(fetchedAt: minutes(-1), items: items, accountStatus: status, presetResults: results,
                        searchedAccounts: searchedAccounts ?? [github.id])
    }

    func display(_ preset: Preset, _ snapshot: Snapshot) -> PresetCountDisplay {
        PresetFreshness.display(for: preset, in: snapshot, accounts: accounts, now: now)
    }

    func needsFetch(_ preset: Preset, _ snapshot: Snapshot) -> Bool {
        PresetFreshness.needsFetchOnOpen(preset, in: snapshot, accounts: accounts, now: now, interval: interval)
    }

    // MARK: - Items and count

    @Test("a preset shows the items of its result that the filter passes, and every matching item of an account that fetches everything")
    func itemsOfThePreset() {
        let inResult = item(1, github), unlabelled = item(2, github, labels: []), notInResult = item(3, github)
        let fromGitLab = item(4, gitlab), unlabelledGitLab = item(5, gitlab, labels: [])
        let snapshot = snapshot([unlabelledGitLab, notInResult, fromGitLab, unlabelled, inResult],
                                results: [result(docs, holding: [inResult, unlabelled], fetchedAt: minutes(-3))],
                                gitlabSyncedAt: minutes(-2))

        let items = PresetFreshness.items(for: docs, in: snapshot, accounts: accounts, now: now)

        #expect(items == [inResult, fromGitLab])
        #expect(display(docs, snapshot).count == 2)
    }

    @Test("a GitHub preset with a complete result counts its items and is dated by the result")
    func fetchedResult() {
        let one = item(1, github), two = item(2, github)
        let snapshot = snapshot([one, two], results: [result(githubDocs, holding: [one, two], fetchedAt: minutes(-3))])

        #expect(display(githubDocs, snapshot)
            == PresetCountDisplay(count: 2, isCapped: false, fetchedAt: minutes(-3), failure: nil, isWaitingForSync: false))
    }

    @Test("a result that stopped before the end of what the provider counted shows a plus")
    func cappedResult() {
        let one = item(1, github), two = item(2, github)
        let snapshot = snapshot([one, two], results: [
            result(githubDocs, holding: [one, two], fetchedAt: minutes(-3), totalCount: 1_500, isComplete: false),
        ])

        #expect(display(githubDocs, snapshot)
            == PresetCountDisplay(count: 2, isCapped: true, fetchedAt: minutes(-3), failure: nil, isWaitingForSync: false))
    }

    @Test("an incomplete result that holds everything the provider counted shows no plus")
    func incompleteWithoutMore() {
        let one = item(1, github), two = item(2, github)
        let snapshot = snapshot([one, two], results: [
            result(githubDocs, holding: [one, two], fetchedAt: minutes(-3), totalCount: 2, isComplete: false),
        ])

        #expect(display(githubDocs, snapshot).isCapped == false)
    }

    @Test("a GitHub preset that was never fetched shows a dash and waits for the sync, although the account synced")
    func neverFetched() {
        let snapshot = snapshot([item(1, github)])

        #expect(display(githubDocs, snapshot)
            == PresetCountDisplay(count: nil, isCapped: false, fetchedAt: nil, failure: nil, isWaitingForSync: true))
    }

    @Test("a result fetched for another selection of the preset reads as never fetched")
    func otherSelection() {
        let one = item(1, github)
        var stale = result(githubDocs, holding: [one], fetchedAt: minutes(-3))
        stale.selection = "an edited filter"
        let snapshot = snapshot([one], results: [stale])

        #expect(display(githubDocs, snapshot)
            == PresetCountDisplay(count: nil, isCapped: false, fetchedAt: nil, failure: nil, isWaitingForSync: true))
    }

    @Test("a query failure stays with the preset next to the last items and their fetch time")
    func failureKeepsLastItems() {
        let one = item(1, github)
        let failure = PresetQueryFailure(code: "422", at: minutes(-1))
        let snapshot = snapshot([one], results: [result(githubDocs, holding: [one], fetchedAt: minutes(-20), failure: failure)])

        #expect(display(githubDocs, snapshot)
            == PresetCountDisplay(count: 1, isCapped: false, fetchedAt: minutes(-20), failure: failure, isWaitingForSync: false))
    }

    @Test("a preset whose every search failed reports the failure and has nothing to count yet")
    func failureBeforeAnyFetch() {
        let failure = PresetQueryFailure(code: "200", at: minutes(-1))
        let snapshot = snapshot([], results: [result(githubDocs, holding: [], fetchedAt: nil, isComplete: false, failure: failure)])

        #expect(display(githubDocs, snapshot)
            == PresetCountDisplay(count: nil, isCapped: false, fetchedAt: nil, failure: failure, isWaitingForSync: true))
    }

    @Test("a GitLab preset is dated by the account's last success and waits only until the account first synced")
    func gitlabPreset() {
        let items = [item(1, gitlab), item(2, gitlab), item(3, gitlab, labels: [])]

        #expect(display(gitlabDocs, snapshot(items, gitlabSyncedAt: minutes(-2)))
            == PresetCountDisplay(count: 2, isCapped: false, fetchedAt: minutes(-2), failure: nil, isWaitingForSync: false))
        #expect(display(gitlabDocs, snapshot(items))
            == PresetCountDisplay(count: nil, isCapped: false, fetchedAt: nil, failure: nil, isWaitingForSync: true))
    }

    @Test("a preset of both accounts whose GitHub part was never fetched waits, with no count and no time")
    func mixedWithGitLabOnly() {
        let snapshot = snapshot([item(1, github), item(2, gitlab)], gitlabSyncedAt: minutes(-2))

        #expect(display(docs, snapshot)
            == PresetCountDisplay(count: nil, isCapped: false, fetchedAt: nil, failure: nil, isWaitingForSync: true))
    }

    @Test("a preset of both accounts whose GitHub result is of another selection waits like one never fetched")
    func mixedWithOtherSelection() {
        let one = item(1, github), two = item(2, gitlab)
        var stale = result(docs, holding: [one], fetchedAt: minutes(-3))
        stale.selection = "an edited filter"
        let snapshot = snapshot([one, two], results: [stale], gitlabSyncedAt: minutes(-2))

        #expect(display(docs, snapshot)
            == PresetCountDisplay(count: nil, isCapped: false, fetchedAt: nil, failure: nil, isWaitingForSync: true))
    }

    @Test("a preset of both accounts counts every part and is dated by the older one once its GitHub part has a result")
    func mixedAfterGitHubResult() {
        let one = item(1, github), two = item(2, gitlab)
        let waiting = snapshot([one, two], gitlabSyncedAt: minutes(-2))
        let fetched = snapshot([one, two], results: [result(docs, holding: [one], fetchedAt: minutes(-4))],
                               gitlabSyncedAt: minutes(-2))

        #expect(display(docs, waiting).isWaitingForSync)
        #expect(display(docs, fetched)
            == PresetCountDisplay(count: 2, isCapped: false, fetchedAt: minutes(-4), failure: nil, isWaitingForSync: false))
    }

    @Test("a GitLab preset counts once its account synced, whatever presets of the searching account have no result")
    func gitlabPresetBesideSearchingAccount() {
        let snapshot = snapshot([item(1, github), item(2, gitlab)], gitlabSyncedAt: minutes(-2))

        #expect(display(gitlabDocs, snapshot)
            == PresetCountDisplay(count: 1, isCapped: false, fetchedAt: minutes(-2), failure: nil, isWaitingForSync: false))
    }

    @Test("a preset of two searching accounts waits while one of them has no result")
    func twoSearchingAccountsOneWithoutResult() {
        let second = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "Second",
                             me: UserRef(login: "carol"))
        let one = item(1, github), two = item(2, second)
        let status = [github.id: FetchStatus(state: .ok, lastSuccessAt: minutes(-1)),
                      second.id: FetchStatus(state: .ok, lastSuccessAt: minutes(-1))]
        func snapshot(_ results: [PresetResult]) -> Snapshot {
            Snapshot(fetchedAt: minutes(-1), items: [one, two], accountStatus: status, presetResults: results,
                     searchedAccounts: [github.id, second.id])
        }
        let first = result(docs, holding: [one], fetchedAt: minutes(-3))
        var other = first
        other.accountID = second.id
        other.itemIDs = [two.id]
        other.fetchedAt = minutes(-7)
        func display(_ snapshot: Snapshot) -> PresetCountDisplay {
            PresetFreshness.display(for: docs, in: snapshot, accounts: [github, second], now: now)
        }

        #expect(display(snapshot([first]))
            == PresetCountDisplay(count: nil, isCapped: false, fetchedAt: nil, failure: nil, isWaitingForSync: true))
        #expect(display(snapshot([first, other]))
            == PresetCountDisplay(count: 2, isCapped: false, fetchedAt: minutes(-7), failure: nil, isWaitingForSync: false))
    }

    @Test("a preset of both accounts with both parts fetched is dated by the older part")
    func mixedWithBoth() {
        let one = item(1, github), two = item(2, gitlab)
        let olderGitHub = snapshot([one, two], results: [result(docs, holding: [one], fetchedAt: minutes(-9))],
                                   gitlabSyncedAt: minutes(-2))
        let olderGitLab = snapshot([one, two], results: [result(docs, holding: [one], fetchedAt: minutes(-3))],
                                   gitlabSyncedAt: minutes(-8))

        #expect(display(docs, olderGitHub)
            == PresetCountDisplay(count: 2, isCapped: false, fetchedAt: minutes(-9), failure: nil, isWaitingForSync: false))
        #expect(display(docs, olderGitLab).fetchedAt == minutes(-8))
    }

    @Test("a preset of both accounts with neither part fetched shows a dash and waits")
    func mixedWithNeither() {
        let snapshot = snapshot([item(1, github), item(2, gitlab)])

        #expect(display(docs, snapshot)
            == PresetCountDisplay(count: nil, isCapped: false, fetchedAt: nil, failure: nil, isWaitingForSync: true))
    }

    @Test("an account outside the searched accounts shows all its matching items and its last success, whatever result it has")
    func accountThatFetchedEverything() {
        let one = item(1, github), two = item(2, github)
        let snapshot = snapshot([one, two], results: [result(githubDocs, holding: [], fetchedAt: minutes(-30))],
                                searchedAccounts: [])

        #expect(display(githubDocs, snapshot)
            == PresetCountDisplay(count: 2, isCapped: false, fetchedAt: minutes(-1), failure: nil, isWaitingForSync: false))
    }

    @Test("a preset scoped to an account that is no longer configured has nothing to wait for")
    func noAccountInScope() {
        let orphan = Preset(name: "Old account", scopes: [PresetScope(accountID: UUID())])

        #expect(display(orphan, snapshot([item(1, github)], gitlabSyncedAt: minutes(-2)))
            == PresetCountDisplay(count: 0, isCapped: false, fetchedAt: nil, failure: nil, isWaitingForSync: false))
    }

    @Test("a count the caller already worked out gives the same display")
    func displayFromCount() {
        let one = item(1, github), two = item(2, gitlab)
        let snapshot = snapshot([one, two], results: [result(docs, holding: [one], fetchedAt: minutes(-3))],
                                gitlabSyncedAt: minutes(-2))
        let count = PresetFreshness.items(for: docs, in: snapshot, accounts: accounts, now: now).count

        #expect(PresetFreshness.display(for: docs, in: snapshot, accounts: accounts, itemCount: count) == display(docs, snapshot))
    }

    // MARK: - Fetch on open

    enum Earlier: String, CaseIterable, Sendable {
        case none, otherSelection, olderThanInterval, exactlyInterval, fresh
    }

    @Test("a GitHub part is fetched on open while its result is missing, of another selection or older than the sync interval",
          arguments: Earlier.allCases)
    func fetchOnOpen(earlier: Earlier) {
        let one = item(1, github)
        var results: [PresetResult] = []
        switch earlier {
        case .none:
            break
        case .otherSelection:
            var stale = result(githubDocs, holding: [one], fetchedAt: minutes(-1))
            stale.selection = "an edited filter"
            results = [stale]
        case .olderThanInterval:
            results = [result(githubDocs, holding: [one], fetchedAt: minutes(-6))]
        case .exactlyInterval:
            results = [result(githubDocs, holding: [one], fetchedAt: minutes(-5))]
        case .fresh:
            results = [result(githubDocs, holding: [one], fetchedAt: minutes(-4))]
        }
        let expected = [Earlier.none, .otherSelection, .olderThanInterval].contains(earlier)

        #expect(needsFetch(githubDocs, snapshot([one], results: results)) == expected)
    }

    @Test("a GitLab preset is never fetched on open: it comes with every sync of the account")
    func gitlabNeverFetchedOnOpen() {
        #expect(!needsFetch(gitlabDocs, snapshot([item(1, gitlab)], gitlabSyncedAt: minutes(-30))))
        #expect(!needsFetch(gitlabDocs, snapshot([item(1, gitlab)])))
    }

    @Test("a preset of both accounts is fetched on open for its GitHub part alone")
    func mixedFetchOnOpen() {
        let one = item(1, github)

        #expect(!needsFetch(docs, snapshot([one], results: [result(docs, holding: [one], fetchedAt: minutes(-1))],
                                           gitlabSyncedAt: minutes(-30))))
        #expect(needsFetch(docs, snapshot([one], gitlabSyncedAt: minutes(-1))))
    }

    @Test("a part whose last search failed less than the sync interval ago is not searched again on open")
    func recentFailureWaits() {
        let one = item(1, github)
        func failed(fetchedAt: Date?, at time: Date) -> Snapshot {
            snapshot([one], results: [result(githubDocs, holding: fetchedAt == nil ? [] : [one], fetchedAt: fetchedAt,
                                              failure: PresetQueryFailure(code: "422", at: time))])
        }

        #expect(!needsFetch(githubDocs, failed(fetchedAt: nil, at: minutes(-1))))
        #expect(!needsFetch(githubDocs, failed(fetchedAt: minutes(-20), at: minutes(-1))))
        #expect(needsFetch(githubDocs, failed(fetchedAt: nil, at: minutes(-6))))
    }

    @Test("an account outside the searched accounts is never fetched on open")
    func notSearchedNeverFetchedOnOpen() {
        #expect(!needsFetch(githubDocs, snapshot([item(1, github)], searchedAccounts: [])))
    }

    func toFetch(_ presets: [Preset], _ snapshot: Snapshot, inFlight: Set<UUID> = []) -> [UUID] {
        PresetFreshness.presetsToFetchOnOpen(presets, in: snapshot, accounts: accounts, now: now, interval: interval,
                                             inFlight: inFlight)
    }

    @Test("a window that opens presets fetches the ones that need it, in their order")
    func presetsToFetchOnOpen() {
        let one = item(1, github)
        let fresh = snapshot([one], results: [result(docs, holding: [one], fetchedAt: minutes(-1))])

        #expect(toFetch([githubDocs, docs, gitlabDocs], fresh) == [githubDocs.id])
        #expect(toFetch([docs, githubDocs], snapshot([one])) == [docs.id, githubDocs.id])
        #expect(toFetch([], snapshot([one])).isEmpty)
    }

    @Test("a preset shown on two tiles of a wall is fetched once")
    func repeatedPresetFetchedOnce() {
        #expect(toFetch([githubDocs, docs, githubDocs], snapshot([item(1, github)])) == [githubDocs.id, docs.id])
    }

    @Test("a preset whose fingerprint changed after its last fetch needs a fetch on open, although the result is fresh")
    func editedPresetNeedsFetchOnOpen() {
        let one = item(1, github)
        var edited = githubDocs
        let snapshot = snapshot([one], results: [result(edited, holding: [one], fetchedAt: minutes(-1))])
        #expect(!needsFetch(edited, snapshot))

        edited.filter.query = "label:bug"

        #expect(edited.selectionFingerprint != githubDocs.selectionFingerprint)
        #expect(needsFetch(edited, snapshot))
    }

    @Test("a preset whose fetch on open is already running is not asked for again")
    func inFlightPresetNotAskedAgain() {
        let snapshot = snapshot([item(1, github)])

        #expect(toFetch([githubDocs, docs], snapshot, inFlight: [githubDocs.id]) == [docs.id])
        #expect(toFetch([githubDocs], snapshot, inFlight: [githubDocs.id]).isEmpty)
    }
}
