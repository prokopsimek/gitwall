import Foundation
import Testing
@testable import GitwallCore

/// Watched repositories, presets and widgets hang on the account record. Signing in a second time must find
/// that record instead of starting an empty twin, and an account that watches nothing must be nameable, because
/// it fetches nothing and still reports a successful sync.
@Suite("Account identity")
struct AccountIdentityTests {
    func github(login: String = "prokop", auth: AuthMethod = .personalAccessToken, sources: [RepoSource] = []) -> Account {
        Account(
            kind: .github,
            baseURL: URL(string: "https://github.com")!,
            displayName: "GitHub (\(login))",
            me: UserRef(login: login),
            authMethod: auth,
            sources: sources
        )
    }

    func gitlab(host: String = "git.applifting.cz", login: String = "prokop", sources: [RepoSource] = []) -> Account {
        Account(
            kind: .gitlab,
            baseURL: URL(string: "https://\(host)")!,
            displayName: "\(host) (\(login))",
            me: UserRef(login: login),
            sources: sources
        )
    }

    // MARK: - The account a new credential belongs to

    @Test("a credential for a login that is already connected to the same server finds that account")
    func findsTheConnectedAccount() {
        let token = github(sources: [.organization(login: "DXHeroes")])
        let config = AppConfig(accounts: [gitlab(), token])

        let found = config.replaceableAccount(kind: .github, baseURL: URL(string: "https://github.com")!, login: "prokop")

        #expect(found?.id == token.id)
    }

    @Test("logins and hosts are compared without case, and a trailing slash does not make another server")
    func comparesLooselyWhereTheServerDoes() {
        let account = github(login: "ProkopSimek")
        let config = AppConfig(accounts: [account])

        let found = config.replaceableAccount(kind: .github, baseURL: URL(string: "https://GitHub.com/")!, login: "prokopsimek")

        #expect(found?.id == account.id)
    }

    @Test("how the account signs in does not matter: a token account is found for a sign-in and the other way round")
    func ignoresTheAuthMethod() {
        let signedIn = github(auth: .oauth(clientID: "client"))
        let config = AppConfig(accounts: [signedIn])

        #expect(config.replaceableAccount(kind: .github, baseURL: signedIn.baseURL, login: "prokop")?.id == signedIn.id)
    }

    @Test("another login, another server or another provider is a different account")
    func differentIdentities() {
        let config = AppConfig(accounts: [github(), gitlab()])

        #expect(config.replaceableAccount(kind: .github, baseURL: URL(string: "https://github.com")!, login: "prokop-work") == nil)
        #expect(config.replaceableAccount(kind: .github, baseURL: URL(string: "https://github.example.com")!, login: "prokop") == nil)
        #expect(config.replaceableAccount(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, login: "prokop") == nil)
        #expect(config.replaceableAccount(kind: .github, baseURL: URL(string: "https://git.applifting.cz")!, login: "prokop") == nil)
        #expect(config.replaceableAccount(kind: .gitlab, baseURL: URL(string: "https://git.applifting.cz:8443")!, login: "prokop") == nil)
    }

    @Test("several accounts under one login are deliberate, so none of them is offered for replacement")
    func severalAccountsUnderOneLogin() {
        // One fine-grained token per organization: the same person twice, on purpose.
        let config = AppConfig(accounts: [
            github(sources: [.organization(login: "DXHeroes")]),
            github(sources: [.organization(login: "Applifting")])
        ])

        #expect(config.replaceableAccount(kind: .github, baseURL: URL(string: "https://github.com")!, login: "prokop") == nil)
    }

    @Test("an account whose owner is unknown is never taken for someone")
    func unknownOwner() {
        let anonymous = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub")
        let config = AppConfig(accounts: [anonymous])

        #expect(config.replaceableAccount(kind: .github, baseURL: anonymous.baseURL, login: "prokop") == nil)
    }

    // MARK: - Accounts that fetch nothing

    @Test("a preset for every account lists each account that watches nothing")
    func idleAccountsOfAnUnscopedPreset() {
        let idle = github()
        let busy = gitlab(sources: [.group(fullPath: "applifting", includeSubgroups: true)])
        let config = AppConfig(accounts: [busy, idle])

        #expect(config.idleAccounts(visibleTo: Preset(name: "All open")).map(\.id) == [idle.id])
    }

    @Test("a scoped preset lists only the idle accounts it looks at")
    func idleAccountsOfAScopedPreset() {
        let idle = github()
        let alsoIdle = gitlab(host: "gitlab.com")
        let busy = gitlab(sources: [.repository(fullName: "applifting/app")])
        let config = AppConfig(accounts: [idle, alsoIdle, busy])
        let preset = Preset(name: "Work", scopes: [PresetScope(accountID: busy.id), PresetScope(accountID: alsoIdle.id)])

        #expect(config.idleAccounts(visibleTo: preset).map(\.id) == [alsoIdle.id])
    }

    // MARK: - Why a preset is empty

    @Test("a preset over an account without repositories is empty because nothing is watched, whatever other accounts watch")
    func nothingWatched() {
        // The reported case: GitLab has repositories, the freshly signed-in GitHub account has none.
        let fresh = github(auth: .oauth(clientID: "client"))
        let busy = gitlab(sources: [.group(fullPath: "applifting", includeSubgroups: true)])
        let config = AppConfig(accounts: [busy, fresh])
        let preset = Preset(name: "Agents repos", scopes: [PresetScope(accountID: fresh.id)])

        #expect(config.emptiness(of: preset) == .nothingWatched(fresh))
    }

    @Test("when only some of a preset's accounts watch nothing, the preset is empty for its filter and names one of them")
    func nothingMatchesWithAnIdleAccount() {
        let fresh = github()
        let busy = gitlab(sources: [.repository(fullName: "applifting/app")])
        let config = AppConfig(accounts: [busy, fresh])

        #expect(config.emptiness(of: Preset(name: "All open")) == .nothingMatches(idle: fresh))
    }

    @Test("when every account of a preset watches something, the preset is simply empty")
    func nothingMatches() {
        let a = github(sources: [.organization(login: "DXHeroes")])
        let b = gitlab(sources: [.repository(fullName: "applifting/app")])
        let config = AppConfig(accounts: [a, b])

        #expect(config.emptiness(of: Preset(name: "All open")) == .nothingMatches(idle: nil))
        #expect(config.emptiness(of: Preset(name: "GitHub", scopes: [PresetScope(accountID: a.id)])) == .nothingMatches(idle: nil))
    }
}
