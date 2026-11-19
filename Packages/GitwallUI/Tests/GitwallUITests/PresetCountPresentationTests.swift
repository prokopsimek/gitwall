import Foundation
import GitwallCore
import Testing
@testable import GitwallUI

@Suite("Preset count presentation")
struct PresetCountPresentationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// An account that fetches each preset with a search of its own, so a preset's result decides what it shows.
    let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub",
                          me: UserRef(login: "bob"))
    let preset = Preset(name: "Reviews")

    func minutes(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    /// What `PresetFreshness` reports for `preset` with this result in the account, or with none.
    func display(
        count: Int, fetchedAt: Date?, hasResult: Bool = true, isCapped: Bool = false, failedAt: Date? = nil
    ) -> PresetCountDisplay {
        let result = PresetResult(
            presetID: preset.id, accountID: account.id, itemIDs: [], fetchedAt: fetchedAt,
            totalCount: isCapped ? 5_000 : 0, isComplete: !isCapped, selection: preset.selectionFingerprint,
            failure: failedAt.map { PresetQueryFailure(code: "422", at: $0) }
        )
        let snapshot = Snapshot(fetchedAt: minutes(-1), items: [], presetResults: hasResult ? [result] : [],
                                searchedAccounts: [account.id])
        return PresetFreshness.display(for: preset, in: snapshot, accounts: [account], itemCount: count)
    }

    @Test("a fetched preset shows its count, and its tooltip when it was fetched")
    func counted() {
        let presentation = PresetCountPresentation(display(count: 12, fetchedAt: minutes(-5)), now: now)

        #expect(presentation.text == "12")
        #expect(presentation.help == "Updated 5 min ago")
        #expect(!presentation.isFailure)
        #expect(presentation.placeholder == nil)
        #expect(!presentation.showsFailureNotice)
        #expect(PresetCountPresentation(display(count: 0, fetchedAt: minutes(-0.2)), now: now).text == "0")
        #expect(PresetCountPresentation(display(count: 0, fetchedAt: minutes(-0.2)), now: now).help == "Updated just now")
    }

    @Test("a search that stopped at the provider's cap shows a plus after the count")
    func capped() {
        let presentation = PresetCountPresentation(display(count: 1_000, fetchedAt: minutes(-2), isCapped: true), now: now)

        #expect(presentation.text == "1000+")
        #expect(presentation.help == "Updated 2 min ago")
    }

    @Test("a preset never fetched shows a dash, says so in the tooltip, and waits for the sync instead of a list")
    func neverFetched() {
        let presentation = PresetCountPresentation(display(count: 0, fetchedAt: nil, hasResult: false), now: now)

        #expect(presentation.text == "–")
        #expect(presentation.help == "Not fetched yet")
        #expect(!presentation.isFailure)
        #expect(presentation.placeholder == .waitingForSync)
    }

    @Test("a failed query keeps the last count and says in the tooltip when that result was fetched")
    func failedAfterAResult() {
        let presentation = PresetCountPresentation(
            display(count: 12, fetchedAt: minutes(-20), failedAt: minutes(-1)), now: now
        )

        #expect(presentation.text == "12")
        #expect(presentation.isFailure)
        #expect(presentation.help == "Query failed · updated 20 min ago")
        #expect(presentation.placeholder == nil)
        #expect(presentation.showsFailureNotice)
    }

    @Test("a query that failed before the preset was ever fetched shows the failure instead of the dash and the waiting")
    func failedBeforeAnyResult() {
        let presentation = PresetCountPresentation(display(count: 0, fetchedAt: nil, failedAt: minutes(-1)), now: now)

        #expect(presentation.text == "Query failed")
        #expect(presentation.help == "Query failed")
        #expect(presentation.isFailure)
        #expect(presentation.placeholder == .queryFailed)
        // The placeholder says it already, in place of the list.
        #expect(!presentation.showsFailureNotice)
    }

    @Test("the menu bar shows the count with its plus, and nothing for no items or a preset never fetched")
    func menuBarText() {
        #expect(PresetCountPresentation.menuBarText(display(count: 12, fetchedAt: minutes(-1))) == "12")
        #expect(PresetCountPresentation.menuBarText(display(count: 1_000, fetchedAt: minutes(-1), isCapped: true)) == "1000+")
        #expect(PresetCountPresentation.menuBarText(display(count: 0, fetchedAt: minutes(-1))) == "")
        #expect(PresetCountPresentation.menuBarText(display(count: 0, fetchedAt: nil, hasResult: false)) == "")
    }

    @Test("the items of a preset are dated by its own fetch, else by the snapshot, but not while it waits for one")
    func fetchedAt() {
        let snapshotTime = minutes(-3)

        #expect(PresetCountPresentation.fetchedAt(display(count: 1, fetchedAt: minutes(-8)), snapshotFetchedAt: snapshotTime)
                == minutes(-8))
        #expect(PresetCountPresentation.fetchedAt(display(count: 0, fetchedAt: nil, hasResult: false),
                                                  snapshotFetchedAt: snapshotTime) == nil)
        // A preset scoped to an account that is gone has no part to date it and nothing to wait for.
        let orphan = Preset(name: "Gone", scopes: [PresetScope(accountID: UUID())])
        let snapshot = Snapshot(fetchedAt: snapshotTime, items: [])
        let undated = PresetFreshness.display(for: orphan, in: snapshot, accounts: [account], itemCount: 0)
        #expect(PresetCountPresentation.fetchedAt(undated, snapshotFetchedAt: snapshotTime) == snapshotTime)
        #expect(PresetCountPresentation.fetchedAt(undated, snapshotFetchedAt: nil) == nil)
    }

    // MARK: - List placeholder

    @Test("a counted preset lists its items, whether or not a fetch runs")
    func listPlaceholderCounted() {
        let counted = display(count: 12, fetchedAt: minutes(-5))

        #expect(PresetCountPresentation.listPlaceholder(counted, isFetching: false) == nil)
        #expect(PresetCountPresentation.listPlaceholder(counted, isFetching: true) == nil)
        // A failed query after a result keeps the last items on screen.
        #expect(PresetCountPresentation.listPlaceholder(
            display(count: 12, fetchedAt: minutes(-20), failedAt: minutes(-1)), isFetching: false) == nil)
        #expect(PresetCountPresentation.listPlaceholder(display(count: 0, fetchedAt: minutes(-5)), isFetching: false) == nil)
    }

    @Test("a preset never fetched shows a spinner while its fetch runs, and waiting for sync otherwise")
    func listPlaceholderWaiting() {
        let waiting = display(count: 0, fetchedAt: nil, hasResult: false)

        #expect(PresetCountPresentation.listPlaceholder(waiting, isFetching: true) == .fetching)
        #expect(PresetCountPresentation.listPlaceholder(waiting, isFetching: false) == .waitingForSync)
    }

    @Test("a query that failed before any result says so, and shows a spinner while a retry runs")
    func listPlaceholderFailed() {
        let failed = display(count: 0, fetchedAt: nil, failedAt: minutes(-1))

        #expect(PresetCountPresentation.listPlaceholder(failed, isFetching: false) == .queryFailed)
        #expect(PresetCountPresentation.listPlaceholder(failed, isFetching: true) == .fetching)
    }

    @Test("while the app has no snapshot or a regular sync runs, a preset without a count is loading, not waiting")
    func listPlaceholderWhileSyncing() {
        let waiting = display(count: 0, fetchedAt: nil, hasResult: false)
        let failed = display(count: 0, fetchedAt: nil, failedAt: minutes(-1))
        let counted = display(count: 12, fetchedAt: minutes(-5))

        #expect(PresetCountPresentation.listPlaceholder(waiting, isFetching: false, isSyncing: true) == .loading)
        #expect(PresetCountPresentation.listPlaceholder(failed, isFetching: false, isSyncing: true) == .loading)
        #expect(PresetCountPresentation.listPlaceholder(waiting, isFetching: true, isSyncing: true) == .fetching)
        #expect(PresetCountPresentation.listPlaceholder(failed, isFetching: true, isSyncing: true) == .fetching)
        #expect(PresetCountPresentation.listPlaceholder(counted, isFetching: false, isSyncing: true) == nil)
        #expect(PresetCountPresentation.listPlaceholder(waiting, isFetching: false, isSyncing: false) == .waitingForSync)
        #expect(PresetCountPresentation.listPlaceholder(failed, isFetching: false, isSyncing: false) == .queryFailed)
    }

    // MARK: - Editor summary

    @Test("the editor says how many items match now for a fetched preset, with a plus at the provider's cap")
    func editorSummaryCounted() {
        #expect(PresetCountPresentation.editorSummary(display(count: 12, fetchedAt: minutes(-5)), isFetching: false)
            == .counted("12 items match now"))
        #expect(PresetCountPresentation.editorSummary(display(count: 0, fetchedAt: minutes(-5)), isFetching: false)
            == .counted("0 items match now"))
        #expect(PresetCountPresentation.editorSummary(display(count: 1_000, fetchedAt: minutes(-2), isCapped: true), isFetching: false)
            == .counted("1000+ items match now"))
        // A fetch that refreshes a counted preset leaves its count on screen.
        #expect(PresetCountPresentation.editorSummary(display(count: 12, fetchedAt: minutes(-5)), isFetching: true)
            == .counted("12 items match now"))
    }

    @Test("the editor shows no number for a preset that waits for its fetch, and a spinner while it is fetched")
    func editorSummaryWaiting() {
        let waiting = display(count: 0, fetchedAt: nil, hasResult: false)

        #expect(PresetCountPresentation.editorSummary(waiting, isFetching: false) == .notFetched)
        #expect(PresetCountPresentation.editorSummary(waiting, isFetching: true) == .fetching)
        #expect(PresetCountPresentation.editorSummary(waiting, isFetching: false).text == "Not fetched yet")
        #expect(PresetCountPresentation.editorSummary(waiting, isFetching: true).text == "Fetching…")
    }

    @Test("the editor says the query failed when it failed before any result, and keeps the count after one")
    func editorSummaryFailed() {
        #expect(PresetCountPresentation.editorSummary(display(count: 0, fetchedAt: nil, failedAt: minutes(-1)), isFetching: false)
            == .queryFailed)
        #expect(PresetCountPresentation.editorSummary(display(count: 0, fetchedAt: nil, failedAt: minutes(-1)), isFetching: true)
            == .queryFailed)
        #expect(PresetCountPresentation.editorSummary(display(count: 3, fetchedAt: minutes(-20), failedAt: minutes(-1)), isFetching: false)
            == .counted("3 items match now"))
    }
}
