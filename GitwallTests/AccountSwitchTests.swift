import Foundation
import GitwallAuth
import GitwallCore
import GitwallGitHub
@testable import Gitwall
import Testing

/// GitHub as one signed-in user sees it: `/user` answers with the login, every search with no items.
private struct GitHubAs: HTTPTransport {
    let login: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://api.github.com")!
        let body = url.path.hasSuffix("/user")
            ? #"{"login":"\#(login)"}"#
            : #"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}

/// Reported 2026-10-04: the GitHub account connected by a token was removed and GitHub was signed in to instead.
/// The sign-in made a second, empty account; the repositories went away with the first one and every preset over
/// GitHub showed nothing, with a successful sync and no word about why.
@Suite("Switching how an account signs in")
@MainActor
struct AccountSwitchTests {
    private let gitHub = URL(string: "https://github.com")!

    private func account(host: String = "github.com", login: String = "prokop", sources: [RepoSource] = []) -> Account {
        Account(
            kind: .github,
            baseURL: URL(string: "https://\(host)")!,
            displayName: "\(host) (\(login))",
            me: UserRef(login: login),
            sources: sources
        )
    }

    /// An installation that already has `accounts`, on a throwaway container, with GitHub answering as `login`.
    private func environment(_ accounts: [Account], signedInAs login: String = "prokop") throws -> AppEnvironment {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitwall-switch-\(UUID().uuidString)")
        let config = accounts.reduce(AppConfig()) { $0.adding($1, pullRequestTerm: "Pull request") }
        try ConfigStore(directoryURL: sandbox).save(config)
        let tokens = InMemoryTokenStore(tokens: Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, StoredToken(accessToken: "token-\($0.id.uuidString)", obtainedAt: Date()))
        }))
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: tokens,
            sandbox: sandbox,
            providers: [.github: GitHubProvider(transport: GitHubAs(login: login))]
        )
        environment.start()
        return environment
    }

    // MARK: - An account that watches nothing says so

    @Test("a preset over an account without repositories names that account, even when another account has some")
    func presetOverAnIdleAccount() async throws {
        let busy = account(host: "github.example.com", sources: [.organization(login: "northwind")])
        let fresh = account()
        let environment = try environment([busy, fresh])
        await environment.refresh()
        let preset = try #require(environment.config.presets.first { $0.scopes == [PresetScope(accountID: fresh.id)] })

        let stored = try #require(environment.config.account(id: fresh.id))
        #expect(environment.listState(for: preset) == .empty(.noRepositories(account: stored)))
    }

    @Test("a preset that also looks at a working account is empty for its filter and still names the idle account")
    func sharedPresetWithAnIdleAccount() async throws {
        let busy = account(host: "github.example.com", sources: [.organization(login: "northwind")])
        let fresh = account()
        let environment = try environment([busy, fresh])
        await environment.refresh()
        let everything = try #require(environment.config.presets.first { $0.scopes.isEmpty })

        let stored = try #require(environment.config.account(id: fresh.id))
        #expect(environment.listState(for: everything) == .empty(.nothingMatches(presetName: everything.name, idle: stored)))
    }

    @Test("Choose Repositories opens the tab on the account that needs them")
    func opensRepositoriesForTheAccount() throws {
        let fresh = account()
        let environment = try environment([fresh])
        var opened: (SettingsTab, UUID?)?
        environment.onOpenSettings = { tab, accountID in opened = (tab, accountID) }

        environment.openSettings(.repositories, accountID: fresh.id)

        #expect(opened?.0 == .repositories)
        #expect(opened?.1 == fresh.id)
    }

    // MARK: - Signing in as someone who is already connected

    @Test("a credential for a login that is already connected finds that account before anything is added")
    func findsTheConnectedAccount() async throws {
        let withToken = account(sources: [.organization(login: "DXHeroes")])
        let environment = try environment([withToken], signedInAs: "Prokop")

        let found = try await environment.connectedAccount(
            kind: .github, baseURL: gitHub, credential: StoredToken(accessToken: "from-sign-in", obtainedAt: Date())
        )

        #expect(found?.id == withToken.id)
        #expect(environment.config.accounts.count == 1, "looking must not add anything")
    }

    @Test("a credential for someone else finds nothing")
    func someoneElse() async throws {
        let environment = try environment([account()], signedInAs: "prokop-work")

        let found = try await environment.connectedAccount(
            kind: .github, baseURL: gitHub, credential: StoredToken(accessToken: "from-sign-in", obtainedAt: Date())
        )

        #expect(found == nil)
    }

    @Test("sample accounts are never offered for replacement")
    func sampleAccounts() async throws {
        // The sample GitHub account belongs to `prokop` too; it has no credential that could be replaced.
        let environment = try environment([], signedInAs: DemoData.me.login)
        environment.enterSampleData()

        let found = try await environment.connectedAccount(
            kind: .github, baseURL: gitHub, credential: StoredToken(accessToken: "from-sign-in", obtainedAt: Date())
        )

        #expect(found == nil)
    }

    @Test("replacing the sign-in keeps the account, its repositories and its presets")
    func replacingKeepsEverything() async throws {
        let withToken = account(sources: [.organization(login: "DXHeroes"), .repository(fullName: "prokopsimek/gitwall")])
        let environment = try environment([withToken])
        let presetsBefore = environment.config.presets

        try await environment.replaceCredential(
            for: try #require(environment.config.account(id: withToken.id)),
            credential: StoredToken(accessToken: "from-sign-in", obtainedAt: Date()),
            authMethod: .oauth(clientID: "client")
        )

        #expect(environment.config.accounts.map(\.id) == [withToken.id])
        let stored = try #require(environment.config.account(id: withToken.id))
        #expect(stored.sources == withToken.sources)
        #expect(stored.authMethod == .oauth(clientID: "client"))
        #expect(environment.config.presets == presetsBefore)
        #expect(try environment.tokenStore.token(for: withToken.id)?.accessToken == "from-sign-in")
    }
}
