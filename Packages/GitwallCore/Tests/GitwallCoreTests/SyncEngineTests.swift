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
        var requestedKinds: [UUID: Set<ItemKind>] = [:]
        var priorityLookup: PriorityLookup = .unsupported
        /// Tokens the priority lookup was called with, in order.
        var priorityTokens: [String] = []

        init(kind: ProviderKind) { self.kind = kind }

        var capabilities: ProviderCapabilities {
            ProviderCapabilities(pullRequestTerm: "Pull request", pullRequestAbbreviation: "PR",
                                 supportsOrganizationSources: true, supportsGroupSources: false,
                                 resolvesTeamReviewRequests: false)
        }
        func verify(baseURL: URL, token: String) async throws -> UserRef { UserRef(login: "me") }
        func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] { [] }
        func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef] { [] }
        func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] {
            requestedKinds[account.id] = kinds
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

        func engine(tokens: [UUID: String]? = nil) -> SyncEngine {
            SyncEngine(
                providers: [.github: githubProvider, .gitlab: gitlabProvider],
                tokens: StaticTokens(tokens: tokens ?? [github.id: "gh", gitlab.id: "gl"]),
                configStore: configStore,
                snapshotStore: snapshotStore,
                now: { now }
            )
        }

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

        env.githubProvider.results[env.github.id] = .failure(.network("offline"))
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
}
