import Foundation
import Testing
@testable import GitwallCore

/// A sync with a selection, for an account whose provider searches each preset on the server.
extension SyncEngineTests {
    /// Lets the GitHub account search presets, saves `presets` into the configuration and a previous snapshot.
    func preparePresetSearch(
        _ env: Env, presets: [Preset], items: [WorkItem] = [], results: [PresetResult] = [],
        status: [UUID: FetchStatus] = [:]
    ) throws {
        env.githubProvider.presetSearchAccounts = [env.github.id]
        var config = try env.configStore.load()
        config.presets = presets
        try env.configStore.save(config)
        try env.snapshotStore.save(Snapshot(fetchedAt: env.minutes(-5), items: items, accountStatus: status,
                                            presetResults: results))
    }

    /// The selection of a sync in which a desktop widget shows each of `presets`.
    func showing(_ presets: [Preset], env: Env) throws -> SyncSelection {
        SyncSelection.presets(in: try env.configStore.load(), widgets: presets.map(\.id), open: [], shownWall: nil)
    }

    /// The search the provider should receive for `preset`.
    func search(_ preset: Preset, repositories: Set<String>? = nil) -> PresetSearch {
        PresetSearch(filter: preset.filter, repositories: repositories, sort: preset.sort, kinds: preset.kinds)
    }

    func found(_ items: [WorkItem], requests: Int = 1) -> Result<PresetFetch, ProviderError> {
        .success(PresetFetch(items: items, totalCount: items.count, isComplete: true, requests: requests))
    }

    /// A result of `preset` in the GitHub account, fetched five minutes before `env.now` for the preset as it is.
    func earlierResult(_ preset: Preset, holding items: [WorkItem], env: Env) -> PresetResult {
        PresetResult(presetID: preset.id, accountID: env.github.id, itemIDs: items.map(\.id), fetchedAt: env.minutes(-5),
                     totalCount: items.count, isComplete: true, selection: preset.selectionFingerprint)
    }

    /// The result a successful search of `preset` in the GitHub account leaves at `env.now`.
    func fetchedResult(_ preset: Preset, holding items: [WorkItem], env: Env) -> PresetResult {
        PresetResult(presetID: preset.id, accountID: env.github.id, itemIDs: items.map(\.id), fetchedAt: env.now,
                     totalCount: items.count, isComplete: true, selection: preset.selectionFingerprint)
    }

    var review: Preset { Preset(name: "Waiting for my review", filter: ItemFilter(relations: [.reviewRequestedFromMe])) }
    var docs: Preset { Preset(name: "Docs", filter: ItemFilter(labelsAny: ["docs"])) }
    var blockers: Preset { Preset(name: "Release blockers", kinds: [.issue], filter: ItemFilter(labelsAny: ["blocker"])) }

    // MARK: - What is searched

    @Test("with a selection an account that searches presets sends one search per selected preset of its scope, nothing else")
    func searchesSelectedPresets() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        var blockers = blockers
        blockers.scopes = [PresetScope(accountID: env.github.id, repositories: ["acme/app", "acme/api"])]
        let gitlabOnly = Preset(name: "GitLab issues", scopes: [PresetScope(accountID: env.gitlab.id)], kinds: [.issue])
        try preparePresetSearch(env, presets: [review, blockers, gitlabOnly, docs])

        _ = try await env.engine().sync(selection: try showing([gitlabOnly, blockers, review], env: env))

        #expect(env.githubProvider.presetSearches == [
            .init(accountID: env.github.id, token: "gh", search: search(review)),
            .init(accountID: env.github.id, token: "gh", search: search(blockers, repositories: ["acme/app", "acme/api"])),
        ])
        #expect(env.githubProvider.requestedKinds[env.github.id] == nil)
        // GitLab cannot search presets, so it fetches what any preset that sees it needs, as before.
        #expect(env.gitlabProvider.presetSearches.isEmpty)
        #expect(env.gitlabProvider.requestedKinds[env.gitlab.id] == [.pullRequest, .issue])
    }

    @Test("an account of the same provider that cannot search presets fetches everything in the same sync")
    func sameProviderWithoutPresetSearch() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let enterprise = Account(kind: .github, baseURL: URL(string: "https://github.acme.test")!, displayName: "Acme",
                                 me: UserRef(login: "bob"))
        var config = try env.configStore.load()
        config.accounts.append(enterprise)
        try env.configStore.save(config)
        let review = review
        try preparePresetSearch(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = found([env.item(1, account: env.github)])
        env.githubProvider.results[enterprise.id] = .success([env.item(7, account: enterprise)])

        let result = try await env.engine(tokens: [env.github.id: "gh", env.gitlab.id: "gl", enterprise.id: "ghes"])
            .sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.presetSearches.map(\.accountID) == [env.github.id])
        #expect(env.githubProvider.requestedKinds[enterprise.id] == [.pullRequest])
        #expect(env.githubProvider.requestedKinds[env.github.id] == nil)
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 7])
        #expect(result.snapshot.accountStatus[enterprise.id]?.state == .ok)
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .ok)
    }

    @Test("without a selection an account that can search presets still fetches everything")
    func withoutSelection() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try preparePresetSearch(env, presets: [review])
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])

        let result = try await env.engine().sync()

        #expect(env.githubProvider.presetSearches.isEmpty)
        #expect(env.githubProvider.requestedKinds[env.github.id] == [.pullRequest])
        #expect(result.snapshot.items.map(\.number) == [1])
        #expect(result.snapshot.presetResults.isEmpty)
    }

    @Test("an account without a selected preset in its scope is asked nothing, not even for its token, and gets no status")
    func nothingToSearch() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let gitlabOnly = Preset(name: "GitLab issues", scopes: [PresetScope(accountID: env.gitlab.id)], kinds: [.issue])
        try preparePresetSearch(env, presets: [gitlabOnly])
        let tokens = FailingTokens(tokens: [env.gitlab.id: "gl"], failures: [env.github.id: .network("offline")])

        let result = try await env.engine(reading: tokens).sync(selection: try showing([gitlabOnly], env: env))

        #expect(env.githubProvider.presetSearches.isEmpty)
        #expect(env.githubProvider.requestedKinds[env.github.id] == nil)
        #expect(env.githubProvider.priorityTokens.isEmpty)
        #expect(result.snapshot.accountStatus[env.github.id] == nil)
    }

    // MARK: - Results and items

    @Test("a searched preset replaces its result; a preset that is not selected keeps its result and the items it holds")
    func searchReplacesResult() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let gone = env.item(1, account: env.github), kept = env.item(2, account: env.github), new = env.item(3, account: env.github)
        let docsResult = earlierResult(docs, holding: [kept], env: env)
        try preparePresetSearch(env, presets: [review, docs], items: [gone, kept],
                                results: [earlierResult(review, holding: [gone], env: env), docsResult])
        env.githubProvider.presetFetches[search(review)] = .success(
            PresetFetch(items: [new], totalCount: 40, isComplete: false, requests: 3)
        )

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        let reviewResult = PresetResult(presetID: review.id, accountID: env.github.id, itemIDs: [new.id], fetchedAt: env.now,
                                        totalCount: 40, isComplete: false, selection: review.selectionFingerprint)
        #expect(result.snapshot.presetResults == [reviewResult, docsResult].sorted(by: PresetResult.precedes))
        #expect(result.snapshot.items.map(\.number).sorted() == [2, 3])
        #expect(try env.snapshotStore.load() == result.snapshot)
    }

    @Test("an item of a searched account that no result holds and no search returned leaves the snapshot")
    func unheldItemLeaves() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review], items: [
            env.item(1, account: env.github), env.item(2, account: env.github), env.item(5, account: env.gitlab),
        ])
        env.githubProvider.presetFetches[search(review)] = found([env.item(2, account: env.github)])
        env.gitlabProvider.results[env.gitlab.id] = .success([env.item(5, account: env.gitlab)])

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(result.snapshot.items.map(\.number).sorted() == [2, 5])
    }

    // MARK: - Failures

    @Test("one preset's query error keeps its previous result with the failure; the others are saved and the account is ok")
    func queryErrorStaysWithPreset() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let held = env.item(1, account: env.github), fresh = env.item(2, account: env.github)
        let reviewResult = earlierResult(review, holding: [held], env: env)
        let earlier = FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5), consecutiveFailures: 1)
        try preparePresetSearch(env, presets: [review, docs], items: [held], results: [reviewResult],
                                status: [env.github.id: earlier])
        env.githubProvider.presetFetches[search(review)] = .failure(.server(status: 422, message: "Validation Failed"))
        env.githubProvider.presetFetches[search(docs)] = found([fresh])

        let result = try await env.engine().sync(selection: try showing([review, docs], env: env))

        var failed = reviewResult
        failed.failure = PresetQueryFailure(code: "422", at: env.now)
        #expect(result.snapshot.presetResults
            == [failed, fetchedResult(docs, holding: [fresh], env: env)].sorted(by: PresetResult.precedes))
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 2])
        let status = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(status.state == .ok)
        #expect(status.message == nil)
        #expect(status.lastSuccessAt == env.now)
        #expect(status.consecutiveFailures == 0)
    }

    @Test("when every search is refused on its own the account's status stays exactly as it was and no priorities are read")
    func onlyQueryErrors() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let earlier = FetchStatus(state: .error, lastSuccessAt: env.minutes(-10), message: "Server error 500: boom",
                                  projectAccess: .denied, consecutiveFailures: 0)
        try preparePresetSearch(env, presets: [review, docs], status: [env.github.id: earlier])
        env.githubProvider.presetFetches[search(review)] = .failure(.server(status: 200, message: "Field 'x' doesn't exist"))
        env.githubProvider.presetFetches[search(docs)] = .failure(.server(status: 400, message: "Bad Request"))

        let result = try await env.engine().sync(selection: try showing([review, docs], env: env))

        #expect(result.snapshot.accountStatus[env.github.id] == earlier)
        #expect(env.githubProvider.priorityTokens.isEmpty)
        let neverFetched = [(review, "200"), (docs, "400")].map { preset, code in
            PresetResult(presetID: preset.id, accountID: env.github.id, itemIDs: [], fetchedAt: nil, totalCount: 0,
                         isComplete: false, selection: preset.selectionFingerprint,
                         failure: PresetQueryFailure(code: code, at: env.now))
        }
        #expect(result.snapshot.presetResults == neverFetched.sorted(by: PresetResult.precedes))
    }

    @Test("a rejected token on the first search stops the account's other searches, keeps every result and item and asks to sign in")
    func unauthorizedStopsAccount() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs, blockers = blockers
        let items = [env.item(1, account: env.github), env.item(2, account: env.github), env.item(3, account: env.github)]
        let results = [earlierResult(review, holding: [items[0]], env: env), earlierResult(docs, holding: [items[1]], env: env)]
            .sorted(by: PresetResult.precedes)
        try preparePresetSearch(env, presets: [review, docs, blockers], items: items, results: results,
                                status: [env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5))])
        env.githubProvider.presetFetches[search(review)] = .failure(.unauthorized)

        let result = try await env.engine().sync(selection: try showing([review, docs, blockers], env: env))

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review)])
        #expect(result.snapshot.presetResults == results)
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 2, 3])
        let status = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(status.state == .needsReauth)
        #expect(status.message == "The token was rejected. Check that it is valid and has the required scopes.")
        #expect(status.lastSuccessAt == env.minutes(-5))
        #expect(env.githubProvider.priorityTokens.isEmpty)
    }

    @Test("an account error after a successful search keeps that result and every previous item, and reads no priorities")
    func accountErrorAfterSuccess() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs, blockers = blockers
        var urgent = env.item(1, account: env.github)
        urgent.projectPriority = .p1
        let other = env.item(2, account: env.github), new = env.item(3, account: env.github)
        let docsResult = earlierResult(docs, holding: [other], env: env)
        try preparePresetSearch(env, presets: [review, docs, blockers], items: [urgent, other],
                                results: [earlierResult(review, holding: [urgent], env: env), docsResult])
        env.githubProvider.presetFetches[search(review)] = found([env.item(1, account: env.github), new])
        env.githubProvider.presetFetches[search(docs)] = .failure(.rateLimited(resetAt: nil))

        let result = try await env.engine().sync(selection: try showing([review, docs, blockers], env: env))

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review), search(docs)])
        #expect(result.snapshot.presetResults
            == [fetchedResult(review, holding: [urgent, new], env: env), docsResult].sorted(by: PresetResult.precedes))
        let byNumber = Dictionary(uniqueKeysWithValues: result.snapshot.items.map { ($0.number, $0.projectPriority) })
        #expect(byNumber == [1: .p1, 2: nil, 3: nil])
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .rateLimited)
        #expect(env.githubProvider.priorityTokens.isEmpty)
    }

    @Test("a gateway error on a search counts quietly and shows on the third sync in a row, keeping the items")
    func gatewayErrorIsQuiet() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let held = env.item(1, account: env.github)
        try preparePresetSearch(env, presets: [review], items: [held], results: [earlierResult(review, holding: [held], env: env)],
                                status: [env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5))])
        env.githubProvider.presetFetches[search(review)] = .failure(.server(status: 502, message: "Bad Gateway"))
        let selection = try showing([review], env: env)

        let first = try await env.engine().sync(selection: selection)
        let quiet = try #require(first.snapshot.accountStatus[env.github.id])
        #expect(quiet.state == .ok)
        #expect(quiet.message == nil)
        #expect(quiet.lastSuccessAt == env.minutes(-5))
        #expect(quiet.consecutiveFailures == 1)
        #expect(first.snapshot.items.map(\.number) == [1])

        let second = try await env.engine(at: env.minutes(5)).sync(selection: selection)
        #expect(second.snapshot.accountStatus[env.github.id]?.state == .ok)
        #expect(second.snapshot.accountStatus[env.github.id]?.consecutiveFailures == 2)

        let third = try await env.engine(at: env.minutes(10)).sync(selection: selection)
        let shown = try #require(third.snapshot.accountStatus[env.github.id])
        #expect(shown.state == .error)
        #expect(shown.message == "Server error 502: Bad Gateway")
        #expect(shown.lastSuccessAt == env.minutes(-5))
        #expect(shown.consecutiveFailures == 3)
        #expect(third.snapshot.items.map(\.number) == [1])
    }

    @Test("an account with presets to search but no token asks to sign in and keeps its results and items")
    func missingTokenWithPresets() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let held = env.item(1, account: env.github)
        let results = [earlierResult(review, holding: [held], env: env)]
        try preparePresetSearch(env, presets: [review], items: [held, env.item(2, account: env.github)], results: results)

        let result = try await env.engine(tokens: [env.gitlab.id: "gl"]).sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.presetSearches.isEmpty)
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .needsReauth)
        #expect(result.snapshot.presetResults == results)
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 2])
    }

    @Test("a rejected token is refreshed once; the search is repeated and the remaining ones use the new token")
    func refreshesToken() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        try preparePresetSearch(env, presets: [review, docs])
        env.githubProvider.presetFetches[search(review)] = .failure(.unauthorized)
        env.githubProvider.presetFetchesAfterToken["gh-new"] = found([env.item(1, account: env.github)])
        env.githubProvider.priorityLookup = .found([:])
        let tokens = RefreshingTokens(first: [env.github.id: "gh-old", env.gitlab.id: "gl"], refreshed: [env.github.id: "gh-new"])

        let result = try await env.engine(reading: tokens).sync(selection: try showing([review, docs], env: env))

        #expect(tokens.refreshCalls == 1)
        #expect(env.githubProvider.presetSearches.map(\.token) == ["gh-old", "gh-new", "gh-new"])
        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review), search(review), search(docs)])
        #expect(env.githubProvider.priorityTokens == ["gh-new"])
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .ok)
        #expect(result.snapshot.items.map(\.number) == [1])
    }

    // MARK: - Priorities

    @Test("the priority lookup runs once after the searches, over every item they found, and its result lands on them")
    func prioritiesAfterSearches() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let one = env.item(1, account: env.github), two = env.item(2, account: env.github), three = env.item(3, account: env.github)
        try preparePresetSearch(env, presets: [review, docs])
        env.githubProvider.presetFetches[search(review)] = found([one, two])
        env.githubProvider.presetFetches[search(docs)] = found([two, three])
        env.githubProvider.priorityLookup = .found([one.id: .p0])

        let result = try await env.engine().sync(selection: try showing([review, docs], env: env))

        #expect(env.githubProvider.priorityTokens == ["gh"])
        #expect(env.githubProvider.priorityItemIDs.count == 1)
        #expect(env.githubProvider.priorityItemIDs.first?.sorted() == [one.id, two.id, three.id].sorted())
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 2, 3])
        let byNumber = Dictionary(uniqueKeysWithValues: result.snapshot.items.map { ($0.number, $0.projectPriority) })
        #expect(byNumber == [1: .p0, 2: nil, 3: nil])
        #expect(result.snapshot.accountStatus[env.github.id]?.projectAccess == .granted)
    }
}
