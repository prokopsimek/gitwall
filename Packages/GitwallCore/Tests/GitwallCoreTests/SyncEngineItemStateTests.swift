import Foundation
import Testing
@testable import GitwallCore

/// Items that left a fresh preset result: the engine asks the provider what became of them, and the notifications of a
/// sync with a selection follow from what it learned.
extension SyncEngineTests {
    /// What the diff of `result` reports, by item number.
    func events(_ result: SyncResult, env: Env) -> [Int: [NotificationEvent]] {
        let changes = SnapshotDiff.changes(from: result.previous, to: result.snapshot, accounts: [env.github, env.gitlab],
                                           searches: result.searches)
        return Dictionary(grouping: changes, by: { $0.item.number }).mapValues { $0.map(\.event).sorted { $0.rawValue < $1.rawValue } }
    }

    /// `result` without `items`, as a result looks once they left it.
    func removing(_ items: [WorkItem], from result: PresetResult) -> PresetResult {
        var result = result
        let gone = Set(items.map(\.id))
        result.itemIDs.removeAll { gone.contains($0) }
        result.totalCount -= items.count
        return result
    }

    func lookup(_ items: [WorkItem], env: Env) -> FakeProvider.ItemStateLookup {
        FakeProvider.ItemStateLookup(accountID: env.github.id, token: "gh", itemIDs: items.map(\.id))
    }

    // MARK: - What is verified

    @Test("a closed or merged item that left a fresh result leaves every result and the snapshot and is reported closed",
          arguments: [ItemState.closed, .merged])
    func confirmedClosed(state: ItemState) async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let gone = env.item(1, account: env.github), kept = env.item(2, account: env.github)
        let docsResult = earlierResult(docs, holding: [gone, kept], env: env)
        try preparePresetSearch(env, presets: [review, docs], items: [gone, kept],
                                results: [earlierResult(review, holding: [gone, kept], env: env), docsResult])
        env.githubProvider.presetFetches[search(review)] = found([kept])
        env.githubProvider.itemStates = [gone.id: state]

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups == [lookup([gone], env: env)])
        #expect(result.snapshot.presetResults == [
            fetchedResult(review, holding: [kept], env: env), removing([gone], from: docsResult),
        ].sorted(by: PresetResult.precedes))
        #expect(result.snapshot.items.map(\.number) == [2])
        #expect(result.searches.closedItemIDs == [gone.id])
        #expect(events(result, env: env) == [1: [.closed]])
    }

    @Test("a not found item that left a fresh result leaves every result and the snapshot without a word")
    func notFoundLeavesSilently() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let gone = env.item(1, account: env.github), kept = env.item(2, account: env.github)
        let docsResult = earlierResult(docs, holding: [gone], env: env)
        try preparePresetSearch(env, presets: [review, docs], items: [gone, kept],
                                results: [earlierResult(review, holding: [gone, kept], env: env), docsResult])
        env.githubProvider.presetFetches[search(review)] = found([kept])
        env.githubProvider.itemStates = [gone.id: .notFound]

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(result.snapshot.presetResults == [
            fetchedResult(review, holding: [kept], env: env), removing([gone], from: docsResult),
        ].sorted(by: PresetResult.precedes))
        #expect(result.snapshot.items.map(\.number) == [2])
        #expect(result.searches.closedItemIDs.isEmpty)
        #expect(events(result, env: env).isEmpty)
    }

    @Test("an open item is refreshed, gets its priority in the one lookup, and stays while another result holds it")
    func openIsRefreshed() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let left = env.item(1, account: env.github), kept = env.item(2, account: env.github)
        var fresh = left
        fresh.title = "Renamed"
        fresh.ciState = .failure
        let docsResult = earlierResult(docs, holding: [left], env: env)
        try preparePresetSearch(env, presets: [review, docs], items: [left, kept],
                                results: [earlierResult(review, holding: [left, kept], env: env), docsResult])
        env.githubProvider.presetFetches[search(review)] = found([kept])
        env.githubProvider.itemStates = [left.id: .open(fresh)]
        env.githubProvider.priorityLookup = .found([left.id: .p1])

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        var expected = fresh
        expected.projectPriority = .p1
        #expect(result.snapshot.items.first { $0.number == 1 } == expected)
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 2])
        #expect(result.snapshot.presetResults.contains(docsResult))
        #expect(env.githubProvider.priorityItemIDs.count == 1)
        #expect(env.githubProvider.priorityItemIDs.first?.sorted() == [left.id, kept.id].sorted())
        #expect(result.searches.closedItemIDs.isEmpty)
        // The item is in both snapshots, so its own changes count as in every sync.
        #expect(events(result, env: env) == [1: [.ciFailed]])
    }

    @Test("an open item that no other result holds leaves the snapshot without a word")
    func openUnheldLeaves() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let left = env.item(1, account: env.github), kept = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review], items: [left, kept],
                                results: [earlierResult(review, holding: [left, kept], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([kept])
        env.githubProvider.itemStates = [left.id: .open(left)]

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups == [lookup([left], env: env)])
        #expect(result.snapshot.items.map(\.number) == [2])
        #expect(events(result, env: env).isEmpty)
    }

    @Test("an item that another search of the same sync returned is not verified")
    func heldByAFreshResult() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let moved = env.item(1, account: env.github)
        try preparePresetSearch(env, presets: [review, docs], items: [moved],
                                results: [earlierResult(review, holding: [moved], env: env), earlierResult(docs, holding: [], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([])
        env.githubProvider.presetFetches[search(docs)] = found([moved])

        let result = try await env.engine().sync(selection: try showing([review, docs], env: env))

        #expect(env.githubProvider.itemStateLookups.isEmpty)
        #expect(result.snapshot.items.map(\.number) == [1])
        #expect(events(result, env: env).isEmpty)
    }

    @Test("an item that only an older result of another preset holds is verified; without an answer it stays where it is")
    func heldOnlyByAnOlderResult() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let left = env.item(1, account: env.github)
        let docsResult = earlierResult(docs, holding: [left], env: env)
        try preparePresetSearch(env, presets: [review, docs], items: [left],
                                results: [earlierResult(review, holding: [left], env: env), docsResult])
        env.githubProvider.presetFetches[search(review)] = found([])

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups == [lookup([left], env: env)])
        #expect(result.snapshot.presetResults.contains(docsResult))
        #expect(result.snapshot.items == [left])
        #expect(events(result, env: env).isEmpty)
    }

    @Test("every item that left a result of the account goes into one lookup")
    func oneLookupPerAccount() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let one = env.item(1, account: env.github), two = env.item(2, account: env.github), three = env.item(3, account: env.github)
        try preparePresetSearch(env, presets: [review, docs], items: [one, two, three],
                                results: [earlierResult(review, holding: [one, two], env: env),
                                          earlierResult(docs, holding: [two, three], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([])
        env.githubProvider.presetFetches[search(docs)] = found([])
        env.githubProvider.itemStates = [one.id: .closed, two.id: .merged, three.id: .notFound]

        let result = try await env.engine().sync(selection: try showing([review, docs], env: env))

        let lookups = env.githubProvider.itemStateLookups
        #expect(lookups.count == 1)
        #expect(lookups.first?.itemIDs.sorted() == [one.id, two.id, three.id].sorted())
        #expect(result.snapshot.items.isEmpty)
        // Two presets held the merged item; it closes once.
        #expect(events(result, env: env) == [1: [.closed], 2: [.closed]])
    }

    @Test("nothing is looked up when no item left a result")
    func nothingLeft() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let one = env.item(1, account: env.github), two = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review], items: [one], results: [earlierResult(review, holding: [one], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([one, two])

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups.isEmpty)
        #expect(result.searches.comparedItemIDs == [one.id, two.id])
        #expect(events(result, env: env) == [2: [.newItem]])
    }

    enum Earlier: String, CaseIterable, Sendable {
        case none, otherSelection, neverFetched
    }

    @Test("a pair without an earlier result of its selection is a baseline: nothing in it is verified or new",
          arguments: Earlier.allCases)
    func baselinePair(earlier: Earlier) async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let left = env.item(1, account: env.github), new = env.item(2, account: env.github)
        var results: [PresetResult] = []
        switch earlier {
        case .none:
            break
        case .otherSelection:
            var stale = earlierResult(review, holding: [left], env: env)
            stale.selection = "an edited filter"
            results = [stale]
        case .neverFetched:
            results = [PresetResult(presetID: review.id, accountID: env.github.id, itemIDs: [left.id], fetchedAt: nil,
                                    totalCount: 1, isComplete: false, selection: review.selectionFingerprint,
                                    failure: PresetQueryFailure(code: "422", at: env.minutes(-5)))]
        }
        try preparePresetSearch(env, presets: [review], items: [left], results: results)
        env.githubProvider.presetFetches[search(review)] = found([new])

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups.isEmpty)
        #expect(result.searches.comparedItemIDs.isEmpty)
        #expect(result.snapshot.items.map(\.number) == [2])
        #expect(events(result, env: env).isEmpty)
    }

    // MARK: - Failures

    @Test("a failed lookup changes no status and no result and sends nothing; what it asked about stays only where held")
    func failedLookup() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let held = env.item(1, account: env.github), unheld = env.item(2, account: env.github)
        let docsResult = earlierResult(docs, holding: [held], env: env)
        try preparePresetSearch(env, presets: [review, docs], items: [held, unheld],
                                results: [earlierResult(review, holding: [held, unheld], env: env), docsResult],
                                status: [env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5))])
        env.githubProvider.presetFetches[search(review)] = found([])
        env.githubProvider.itemStateFailure = .rateLimited(resetAt: nil)

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups.count == 1)
        #expect(result.snapshot.accountStatus[env.github.id] == FetchStatus(state: .ok, lastSuccessAt: env.now))
        #expect(result.snapshot.presetResults
            == [fetchedResult(review, holding: [], env: env), docsResult].sorted(by: PresetResult.precedes))
        #expect(result.snapshot.items == [held])
        #expect(result.searches.closedItemIDs.isEmpty)
        #expect(events(result, env: env).isEmpty)
    }

    @Test("an account error after a search looks nothing up; what that search brought new is still news")
    func accountErrorSkipsLookup() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let left = env.item(1, account: env.github), new = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review, docs], items: [left],
                                results: [earlierResult(review, holding: [left], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([new])
        env.githubProvider.presetFetches[search(docs)] = .failure(.rateLimited(resetAt: nil))

        let result = try await env.engine().sync(selection: try showing([review, docs], env: env))

        #expect(env.githubProvider.itemStateLookups.isEmpty)
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .rateLimited)
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 2])
        #expect(events(result, env: env) == [2: [.newItem]])
    }

    // MARK: - What the sync reports

    @Test("the result names the accounts that searched, whatever came of it, and not those that fetched everything")
    func searchedAccounts() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = .failure(.server(status: 422, message: "Validation Failed"))

        let selected = try await env.engine().sync(selection: try showing([review], env: env))
        let everything = try await env.engine().sync()

        #expect(selected.searches == SearchFindings(accounts: [env.github.id], closedItemIDs: [], comparedItemIDs: []))
        #expect(everything.searches == .none)
    }

    // MARK: - Notifications that must not fire

    @Test("the first sync with a selection after the update sends nothing for the searching account")
    func firstSyncAfterTheUpdate() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        // The previous snapshot came from a full fetch: items, but no preset results.
        let before = (1...3).map { env.item($0, account: env.github) }
        try preparePresetSearch(env, presets: [review], items: before,
                                status: [env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5))])
        var asked = env.item(4, account: env.github)
        asked.requestedReviewers = [UserRef(login: "me")]
        env.githubProvider.presetFetches[search(review)] = found([env.item(3, account: env.github), asked])

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups.isEmpty)
        #expect(result.snapshot.items.map(\.number).sorted() == [3, 4])
        #expect(events(result, env: env).isEmpty)
    }

    @Test("a preset this sync did not search keeps its items and sends nothing")
    func unsearchedPresetIsQuiet() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let shown = env.item(1, account: env.github), hidden = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review, docs], items: [shown, hidden],
                                results: [earlierResult(review, holding: [shown], env: env),
                                          earlierResult(docs, holding: [hidden], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([shown])

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups.isEmpty)
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 2])
        #expect(events(result, env: env).isEmpty)
    }

    @Test("the items of a deleted preset leave without a word and come back with a first result without one")
    func deletedPresetIsQuiet() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, deleted = blockers, docs = docs
        let shown = env.item(1, account: env.github), orphan = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review], items: [shown, orphan],
                                results: [earlierResult(review, holding: [shown], env: env),
                                          earlierResult(deleted, holding: [orphan], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([shown])

        let first = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(first.snapshot.items.map(\.number) == [1])
        #expect(events(first, env: env).isEmpty)

        var config = try env.configStore.load()
        config.presets.append(docs)
        try env.configStore.save(config)
        env.githubProvider.presetFetches[search(docs)] = found([orphan])
        let second = try await env.engine(at: env.minutes(5)).sync(selection: try showing([review, docs], env: env))

        #expect(second.snapshot.items.map(\.number).sorted() == [1, 2])
        #expect(env.githubProvider.itemStateLookups.isEmpty)
        #expect(events(second, env: env).isEmpty)
    }
}
