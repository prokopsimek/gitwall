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
        var requestedKinds: [UUID: Set<ItemKind>] = [:]

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
            guard let result = results[account.id] else { return [] }
            return try result.get()
        }
    }

    struct StaticTokens: TokenReading {
        var tokens: [UUID: String]
        func token(for accountID: UUID) async throws -> String? { tokens[accountID] }
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
}
