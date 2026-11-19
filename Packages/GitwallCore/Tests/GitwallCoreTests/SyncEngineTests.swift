import Foundation
import Testing
@testable import GitwallCore

@Suite("SyncEngine")
struct SyncEngineTests {
    /// Scripted provider: returns items per account or throws.
    final class FakeProvider: GitProvider, @unchecked Sendable {
        // @unchecked: mutated only before the engine runs; tests are single-threaded per instance.
        let kind: ProviderKind
        var results: [UUID: Result<[WorkItem], ProviderError>] = [:]
        /// Overrides `results` when the call arrives with this token, so a retry after a refresh can succeed.
        var resultsAfterToken: [String: [WorkItem]] = [:]
        /// Like `resultsAfterToken`, for a retry after a refresh that fails too.
        var failuresAfterToken: [String: ProviderError] = [:]
        var requestedKinds: [UUID: Set<ItemKind>] = [:]
        var priorityLookup: PriorityLookup = .unsupported
        /// Tokens the priority lookup was called with, in order.
        var priorityTokens: [String] = []

        init(kind: ProviderKind) { self.kind = kind }

        var capabilities: ProviderCapabilities {
            ProviderCapabilities(pullRequestTerm: "Pull request", pullRequestAbbreviation: "PR",
                                 supportsOrganizationSources: true, supportsGroupSources: false,
                                 resolvesTeamReviewRequests: false, hostName: "GitHub")
        }
        func verify(baseURL: URL, token: String) async throws -> UserRef { UserRef(login: "me") }
        func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] { [] }
        func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef] { [] }
        func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] {
            requestedKinds[account.id] = kinds
            if let error = failuresAfterToken[token] { throw error }
            if let items = resultsAfterToken[token] { return items }
            guard let result = results[account.id] else { return [] }
            return try result.get()
        }
        func projectPriorities(account: Account, token: String, items: [WorkItem]) async -> PriorityLookup {
            priorityTokens.append(token)
            return priorityLookup
        }
    }

    struct StaticTokens: TokenReading {
        var tokens: [UUID: String]
        func token(for accountID: UUID) async throws -> String? { tokens[accountID] }
    }

    /// Hands out a second token once, the way a refreshing reader does after the provider rejected the first.
    final class RefreshingTokens: TokenReading, @unchecked Sendable {
        let first: [UUID: String]
        let refreshed: [UUID: String]
        var refreshCalls = 0

        init(first: [UUID: String], refreshed: [UUID: String]) {
            self.first = first
            self.refreshed = refreshed
        }

        func token(for accountID: UUID) async throws -> String? { first[accountID] }
        func tokenAfterUnauthorized(for accountID: UUID) async throws -> String? {
            refreshCalls += 1
            return refreshed[accountID]
        }
    }

    struct Env {
        let dir: URL
        let configStore: ConfigStore
        let snapshotStore: SnapshotStore
        let github = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub", me: UserRef(login: "me"))
        let gitlab = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, displayName: "GitLab", me: UserRef(login: "me"))
        let githubProvider = FakeProvider(kind: .github)
        let gitlabProvider = FakeProvider(kind: .gitlab)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitwall-sync-\(UUID().uuidString)", isDirectory: true)
            configStore = ConfigStore(directoryURL: dir)
            snapshotStore = SnapshotStore(directoryURL: dir)
            try configStore.save(AppConfig(accounts: [github, gitlab], presets: Preset.defaults()))
        }

        func engine(tokens: [UUID: String]? = nil, at time: Date? = nil) -> SyncEngine {
            engine(reading: StaticTokens(tokens: tokens ?? [github.id: "gh", gitlab.id: "gl"]), at: time)
        }

        /// An engine whose clock reads `time`, `now` by default, so a later sync can be told apart from an earlier one.
        func engine(reading tokens: any TokenReading, at time: Date? = nil) -> SyncEngine {
            let time = time ?? now
            return SyncEngine(
                providers: [.github: githubProvider, .gitlab: gitlabProvider],
                tokens: tokens,
                configStore: configStore,
                snapshotStore: snapshotStore,
                now: { time }
            )
        }

        func minutes(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

        func item(_ n: Int, account: Account) -> WorkItem {
            WorkItem(accountID: account.id, kind: .pullRequest, repoFullName: "acme/app", number: n, title: "PR \(n)",
                     url: URL(string: "https://example.com/\(n)")!, author: UserRef(login: "me"),
                     createdAt: now, updatedAt: now)
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test("merges items of all accounts, saves the snapshot and reports ok per account")
    func happyPath() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        env.gitlabProvider.results[env.gitlab.id] = .success([env.item(2, account: env.gitlab)])

        let result = try await env.engine().sync()

        #expect(result.snapshot.items.map(\.number).sorted() == [1, 2])
        #expect(result.snapshot.fetchedAt == env.now)
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .ok)
        #expect(result.snapshot.accountStatus[env.gitlab.id]?.state == .ok)
        #expect(try env.snapshotStore.load() == result.snapshot)
        #expect(result.previous == nil)
    }

    @Test("a failing account keeps its previous items and is marked as error")
    func partialFailure() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        env.gitlabProvider.results[env.gitlab.id] = .success([env.item(2, account: env.gitlab)])
        _ = try await env.engine().sync()

        env.gitlabProvider.results[env.gitlab.id] = .failure(.server(status: 500, message: "boom"))
        env.githubProvider.results[env.github.id] = .success([env.item(3, account: env.github)])
        let result = try await env.engine().sync()

        #expect(result.snapshot.items.map(\.number).sorted() == [2, 3])
        #expect(result.snapshot.accountStatus[env.gitlab.id]?.state == .error)
        #expect(result.snapshot.accountStatus[env.gitlab.id]?.message?.contains("500") == true)
        #expect(result.snapshot.accountStatus[env.gitlab.id]?.lastSuccessAt == env.now)
        #expect(result.previous?.items.map(\.number).sorted() == [1, 2])
    }

    @Test("unauthorized and rate limited map to dedicated states")
    func errorStates() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        env.gitlabProvider.results[env.gitlab.id] = .failure(.rateLimited(resetAt: nil))

        let result = try await env.engine().sync()

        #expect(result.snapshot.accountStatus[env.github.id]?.state == .needsReauth)
        #expect(result.snapshot.accountStatus[env.gitlab.id]?.state == .rateLimited)
    }

    @Test("an account without a token needs re-authentication and is not fetched")
    func missingToken() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])

        let result = try await env.engine(tokens: [env.gitlab.id: "gl"]).sync()

        #expect(result.snapshot.accountStatus[env.github.id]?.state == .needsReauth)
        #expect(env.githubProvider.requestedKinds[env.github.id] == nil)
    }

    @Test("only the item kinds some preset needs are requested from each account")
    func requestedKinds() async throws {
        let env = try Env()
        defer { env.cleanup() }
        var config = try env.configStore.load()
        config.presets = [
            Preset(name: "GitHub PRs", scopes: [PresetScope(accountID: env.github.id)], kinds: [.pullRequest]),
            Preset(name: "GitLab issues", scopes: [PresetScope(accountID: env.gitlab.id)], kinds: [.issue]),
        ]
        try env.configStore.save(config)

        _ = try await env.engine().sync()

        #expect(env.githubProvider.requestedKinds[env.github.id] == [.pullRequest])
        #expect(env.gitlabProvider.requestedKinds[env.gitlab.id] == [.issue])
    }

    @Test("accounts without any preset are still fetched for both kinds")
    func noPresets() async throws {
        let env = try Env()
        defer { env.cleanup() }
        var config = try env.configStore.load()
        config.presets = []
        try env.configStore.save(config)

        _ = try await env.engine().sync()

        #expect(env.githubProvider.requestedKinds[env.github.id] == [.pullRequest, .issue])
    }
    @Test("a rejected token is refreshed once and the fetch is retried with it")
    func retriesAfterRefresh() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let item = env.item(1, account: env.github)
        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        env.githubProvider.resultsAfterToken["gh-new"] = [item]
        let tokens = RefreshingTokens(first: [env.github.id: "gh-old", env.gitlab.id: "gl"], refreshed: [env.github.id: "gh-new"])
        let engine = SyncEngine(providers: [.github: env.githubProvider, .gitlab: env.gitlabProvider],
                                tokens: tokens, configStore: env.configStore, snapshotStore: env.snapshotStore, now: { env.now })

        let result = try await engine.sync()

        #expect(tokens.refreshCalls == 1)
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .ok)
        #expect(result.snapshot.items.contains { $0.id == item.id })
    }

    @Test("when no refreshed token is available the account needs a new sign-in")
    func needsReauthWithoutRefresh() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        let tokens = RefreshingTokens(first: [env.github.id: "gh-old", env.gitlab.id: "gl"], refreshed: [:])
        let engine = SyncEngine(providers: [.github: env.githubProvider, .gitlab: env.gitlabProvider],
                                tokens: tokens, configStore: env.configStore, snapshotStore: env.snapshotStore, now: { env.now })

        let result = try await engine.sync()

        #expect(tokens.refreshCalls == 1)
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .needsReauth)
    }

    // MARK: - Priorities

    @Test("project priorities land on the items and the account reads projects")
    func prioritiesFound() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let urgent = env.item(1, account: env.github)
        env.githubProvider.results[env.github.id] = .success([urgent, env.item(2, account: env.github)])
        env.githubProvider.priorityLookup = .found([urgent.id: .p0])

        let result = try await env.engine().sync()

        let byNumber = Dictionary(uniqueKeysWithValues: result.snapshot.items.map { ($0.number, $0.projectPriority) })
        #expect(byNumber[1] == .p0)
        #expect(byNumber[2] == .some(nil))
        #expect(result.snapshot.accountStatus[env.github.id]?.projectAccess == .granted)
        #expect(env.githubProvider.priorityTokens == ["gh"])
    }

    @Test("a token that may not read projects keeps the sync ok and marks the account")
    func prioritiesDenied() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        env.githubProvider.priorityLookup = .missingPermission

        let result = try await env.engine().sync()

        let status = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(status.state == .ok)
        #expect(status.projectAccess == .denied)
        #expect(result.snapshot.items.map(\.number) == [1])
        #expect(result.snapshot.items.allSatisfy { $0.projectPriority == nil })
    }

    @Test("a lookup that fails for a passing reason keeps the previous priorities and access")
    func prioritiesFailedKeepsPrevious() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let urgent = env.item(1, account: env.github)
        env.githubProvider.results[env.github.id] = .success([urgent, env.item(2, account: env.github)])
        env.githubProvider.priorityLookup = .found([urgent.id: .p1])
        _ = try await env.engine().sync()

        env.githubProvider.results[env.github.id] = .success([urgent, env.item(2, account: env.github), env.item(3, account: env.github)])
        env.githubProvider.priorityLookup = .failed("rate limited")
        let result = try await env.engine().sync()

        let byNumber = Dictionary(uniqueKeysWithValues: result.snapshot.items.map { ($0.number, $0.projectPriority) })
        #expect(byNumber[1] == .p1)
        #expect(byNumber[3] == .some(nil))
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .ok)
        #expect(result.snapshot.accountStatus[env.github.id]?.projectAccess == .granted)
    }

    @Test("a provider without projects leaves the access unknown; a failed fetch keeps the last one")
    func prioritiesUnsupportedAndFailedFetch() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        env.githubProvider.priorityLookup = .missingPermission
        env.gitlabProvider.results[env.gitlab.id] = .success([env.item(2, account: env.gitlab)])
        _ = try await env.engine().sync()

        // Not a passing outage, which would keep the account ok; see the quiet period tests below.
        env.githubProvider.results[env.github.id] = .failure(.server(status: 500, message: "boom"))
        let result = try await env.engine().sync()

        #expect(result.snapshot.accountStatus[env.gitlab.id]?.projectAccess == nil)
        #expect(result.snapshot.accountStatus[env.github.id]?.state == .error)
        #expect(result.snapshot.accountStatus[env.github.id]?.projectAccess == .denied)
    }

    @Test("after a refresh the priority lookup uses the new token")
    func prioritiesUseRefreshedToken() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        env.githubProvider.resultsAfterToken["gh-new"] = [env.item(1, account: env.github)]
        env.githubProvider.priorityLookup = .found([:])
        let tokens = RefreshingTokens(first: [env.github.id: "gh-old", env.gitlab.id: "gl"], refreshed: [env.github.id: "gh-new"])
        let engine = SyncEngine(providers: [.github: env.githubProvider, .gitlab: env.gitlabProvider],
                                tokens: tokens, configStore: env.configStore, snapshotStore: env.snapshotStore, now: { env.now })

        _ = try await engine.sync()

        #expect(env.githubProvider.priorityTokens == ["gh-new"])
    }

    // MARK: - Quiet period

    /// Hands out stored tokens, except for accounts whose read throws.
    struct FailingTokens: TokenReading {
        var tokens: [UUID: String]
        var failures: [UUID: ProviderError]
        func token(for accountID: UUID) async throws -> String? {
            if let error = failures[accountID] { throw error }
            return tokens[accountID]
        }
    }

    @Test("the first failure caused by a gateway error or a lost connection keeps the account ok with its data",
          arguments: [
              ProviderError.server(status: 502, message: "Bad Gateway"),
              .server(status: 503, message: "Service Unavailable"),
              .server(status: 504, message: "Gateway Timeout"),
              .network("The network connection was lost."),
          ])
    func firstTransientFailureIsQuiet(error: ProviderError) async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        env.githubProvider.priorityLookup = .found([:])
        _ = try await env.engine().sync()

        env.githubProvider.results[env.github.id] = .failure(error)
        let result = try await env.engine(at: env.minutes(5)).sync()

        let status = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(status.state == .ok)
        #expect(status.message == nil)
        #expect(status.lastSuccessAt == env.now)
        #expect(status.consecutiveFailures == 1)
        #expect(status.projectAccess == .granted)
        #expect(result.snapshot.items.map(\.number) == [1])
    }

    @Test("the second failure in a row stays quiet; the third shows the error as before and the count goes on")
    func thirdTransientFailureShows() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        _ = try await env.engine().sync()
        env.githubProvider.results[env.github.id] = .failure(.server(status: 503, message: "Service Unavailable"))
        _ = try await env.engine(at: env.minutes(5)).sync()

        let second = try await env.engine(at: env.minutes(10)).sync().snapshot.accountStatus[env.github.id]
        #expect(second?.state == .ok)
        #expect(second?.message == nil)
        #expect(second?.lastSuccessAt == env.now)
        #expect(second?.consecutiveFailures == 2)

        let third = try await env.engine(at: env.minutes(15)).sync()
        let status = try #require(third.snapshot.accountStatus[env.github.id])
        #expect(status.state == .error)
        #expect(status.message == "Server error 503: Service Unavailable")
        #expect(status.lastSuccessAt == env.now)
        #expect(status.consecutiveFailures == 3)
        #expect(third.snapshot.items.map(\.number) == [1])

        let fourth = try await env.engine(at: env.minutes(20)).sync().snapshot.accountStatus[env.github.id]
        #expect(fourth?.state == .error)
        #expect(fourth?.consecutiveFailures == 4)
    }

    @Test("a success after failed syncs resets the count, so the next outage starts quiet again")
    func successResetsTheCount() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        _ = try await env.engine().sync()
        env.githubProvider.results[env.github.id] = .failure(.network("The request timed out."))
        _ = try await env.engine(at: env.minutes(5)).sync()

        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github), env.item(2, account: env.github)])
        let recovered = try await env.engine(at: env.minutes(10)).sync()
        let status = try #require(recovered.snapshot.accountStatus[env.github.id])
        #expect(status.state == .ok)
        #expect(status.consecutiveFailures == 0)
        #expect(status.lastSuccessAt == env.minutes(10))
        #expect(recovered.snapshot.items.map(\.number).sorted() == [1, 2])

        env.githubProvider.results[env.github.id] = .failure(.network("The request timed out."))
        let next = try await env.engine(at: env.minutes(15)).sync().snapshot.accountStatus[env.github.id]
        #expect(next?.state == .ok)
        #expect(next?.consecutiveFailures == 1)
        #expect(next?.lastSuccessAt == env.minutes(10))
    }

    @Test("a rejected token and a rate limit show at once in the middle of a series and end it")
    func authAndRateLimitInterruptTheSeries() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let tokens = RefreshingTokens(first: [env.github.id: "gh", env.gitlab.id: "gl"], refreshed: [env.github.id: "gh-new"])
        _ = try await env.engine(reading: tokens).sync()
        env.githubProvider.results[env.github.id] = .failure(.server(status: 502, message: "Bad Gateway"))
        env.gitlabProvider.results[env.gitlab.id] = .failure(.network("The request timed out."))
        let series = try await env.engine(reading: tokens, at: env.minutes(5)).sync()
        #expect(series.snapshot.accountStatus[env.github.id]?.consecutiveFailures == 1)
        #expect(series.snapshot.accountStatus[env.gitlab.id]?.consecutiveFailures == 1)

        // The refreshed token is rejected too, so the silent refresh does not help.
        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        env.githubProvider.failuresAfterToken["gh-new"] = .unauthorized
        env.gitlabProvider.results[env.gitlab.id] = .failure(.rateLimited(resetAt: nil))
        let result = try await env.engine(reading: tokens, at: env.minutes(10)).sync()

        #expect(tokens.refreshCalls == 1)
        let github = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(github.state == .needsReauth)
        #expect(github.message == "The token was rejected. Check that it is valid and has the required scopes.")
        #expect(github.lastSuccessAt == env.now)
        #expect(github.consecutiveFailures == 0)
        let gitlab = try #require(result.snapshot.accountStatus[env.gitlab.id])
        #expect(gitlab.state == .rateLimited)
        #expect(gitlab.message == "API rate limit reached.")
        #expect(gitlab.consecutiveFailures == 0)
    }

    @Test("a gateway error on the retry after a token refresh stays quiet like any other")
    func transientFailureAfterRefreshIsQuiet() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let tokens = RefreshingTokens(first: [env.github.id: "gh", env.gitlab.id: "gl"], refreshed: [env.github.id: "gh-new"])
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        _ = try await env.engine(reading: tokens).sync()

        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        env.githubProvider.failuresAfterToken["gh-new"] = .server(status: 504, message: "Gateway Timeout")
        let result = try await env.engine(reading: tokens, at: env.minutes(5)).sync()

        #expect(tokens.refreshCalls == 1)
        let status = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(status.state == .ok)
        #expect(status.message == nil)
        #expect(status.consecutiveFailures == 1)
        #expect(result.snapshot.items.map(\.number) == [1])
    }

    @Test("any other provider error shows at once and ends the series; a gateway error after it keeps it on screen",
          arguments: [
              ProviderError.server(status: 500, message: "Internal Server Error"),
              .invalidResponse("missing data"),
              .notFound("acme/app"),
          ])
    func otherErrorsInterruptTheSeries(error: ProviderError) async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        _ = try await env.engine().sync()
        env.githubProvider.results[env.github.id] = .failure(.server(status: 502, message: "Bad Gateway"))
        let series = try await env.engine(at: env.minutes(5)).sync()
        #expect(series.snapshot.accountStatus[env.github.id]?.consecutiveFailures == 1)

        env.githubProvider.results[env.github.id] = .failure(error)
        let result = try await env.engine(at: env.minutes(10)).sync()
        let status = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(status.state == .error)
        #expect(status.message == error.localizedDescription)
        #expect(status.lastSuccessAt == env.now)
        #expect(status.consecutiveFailures == 0)
        #expect(result.snapshot.items.map(\.number) == [1])

        // A passing outage now must not hide the error already on screen, nor swap its message for a vaguer one.
        env.githubProvider.results[env.github.id] = .failure(.server(status: 502, message: "Bad Gateway"))
        let again = try await env.engine(at: env.minutes(15)).sync().snapshot.accountStatus[env.github.id]
        #expect(again?.state == .error)
        #expect(again?.message == error.localizedDescription)
        #expect(again?.lastSuccessAt == env.now)
        #expect(again?.consecutiveFailures == 1)
    }

    @Test("a lost connection after a rejected token keeps asking to sign in until the third failure in a row")
    func transientFailureKeepsVisibleError() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        env.githubProvider.priorityLookup = .missingPermission
        _ = try await env.engine().sync()
        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        let rejected = try await env.engine(at: env.minutes(5)).sync().snapshot.accountStatus[env.github.id]
        #expect(rejected?.state == .needsReauth)

        env.githubProvider.results[env.github.id] = .failure(.network("The Internet connection appears to be offline."))
        let first = try await env.engine(at: env.minutes(10)).sync()
        let status = try #require(first.snapshot.accountStatus[env.github.id])
        #expect(status.state == .needsReauth)
        #expect(status.message == "The token was rejected. Check that it is valid and has the required scopes.")
        #expect(status.lastSuccessAt == env.now)
        #expect(status.projectAccess == .denied)
        #expect(status.consecutiveFailures == 1)
        #expect(first.snapshot.items.map(\.number) == [1])

        let second = try await env.engine(at: env.minutes(15)).sync().snapshot.accountStatus[env.github.id]
        #expect(second?.state == .needsReauth)
        #expect(second?.message == "The token was rejected. Check that it is valid and has the required scopes.")
        #expect(second?.consecutiveFailures == 2)

        let third = try await env.engine(at: env.minutes(20)).sync().snapshot.accountStatus[env.github.id]
        #expect(third?.state == .error)
        #expect(third?.message == "Network error: The Internet connection appears to be offline.")
        #expect(third?.lastSuccessAt == env.now)
        #expect(third?.consecutiveFailures == 3)
    }

    @Test("a rate limit on the retry after a token refresh is reported as a rate limit")
    func rateLimitAfterRefresh() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let tokens = RefreshingTokens(first: [env.github.id: "gh", env.gitlab.id: "gl"], refreshed: [env.github.id: "gh-new"])
        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        env.githubProvider.failuresAfterToken["gh-new"] = .rateLimited(resetAt: nil)

        let result = try await env.engine(reading: tokens).sync()

        #expect(tokens.refreshCalls == 1)
        let status = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(status.state == .rateLimited)
        #expect(status.message == "API rate limit reached.")
        #expect(status.consecutiveFailures == 0)
    }

    @Test("a token that cannot be read and a missing provider show at once in the middle of a series")
    func setupFailuresInterruptTheSeries() async throws {
        let env = try Env()
        defer { env.cleanup() }
        _ = try await env.engine().sync()
        env.githubProvider.results[env.github.id] = .failure(.server(status: 503, message: "Service Unavailable"))
        env.gitlabProvider.results[env.gitlab.id] = .failure(.server(status: 503, message: "Service Unavailable"))
        let series = try await env.engine(at: env.minutes(5)).sync()
        #expect(series.snapshot.accountStatus[env.github.id]?.consecutiveFailures == 1)

        // Even a read that fails like a lost connection is no outage of the provider, so it is not held back.
        let later = env.minutes(10)
        let engine = SyncEngine(
            providers: [.github: env.githubProvider],
            tokens: FailingTokens(tokens: [env.gitlab.id: "gl"], failures: [env.github.id: .network("offline")]),
            configStore: env.configStore, snapshotStore: env.snapshotStore, now: { later }
        )
        let result = try await engine.sync()

        let github = result.snapshot.accountStatus[env.github.id]
        #expect(github?.state == .error)
        #expect(github?.message == "Could not read the token: Network error: offline")
        #expect(github?.consecutiveFailures == 0)
        let gitlab = result.snapshot.accountStatus[env.gitlab.id]
        #expect(gitlab?.state == .error)
        #expect(gitlab?.message == "No provider registered for gitlab.")
        #expect(gitlab?.consecutiveFailures == 0)
    }

    @Test("an account that never synced stays quiet on a gateway error and has no date yet")
    func neverSyncedAccountIsQuiet() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .failure(.server(status: 502, message: "Bad Gateway"))

        let result = try await env.engine().sync()

        let status = try #require(result.snapshot.accountStatus[env.github.id])
        #expect(status.state == .ok)
        #expect(status.message == nil)
        #expect(status.lastSuccessAt == nil)
        #expect(status.consecutiveFailures == 1)
        #expect(result.snapshot.items.isEmpty)
    }
}
