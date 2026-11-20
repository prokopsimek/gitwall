import Foundation
import Testing
@testable import GitwallCore

/// A provider that implements only what every provider must: no preset search of its own.
private struct PlainProvider: GitProvider {
    let kind: ProviderKind = .gitlab
    let capabilities = ProviderCapabilities(
        pullRequestTerm: "Merge request", pullRequestAbbreviation: "MR", supportsOrganizationSources: false,
        supportsGroupSources: true, resolvesTeamReviewRequests: false, hostName: "GitLab"
    )
    func verify(baseURL: URL, token: String) async throws -> UserRef { UserRef(login: "bob") }
    func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] { [] }
    func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef] { [] }
    func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] { [] }
}

@Suite("Preset search at the provider")
struct PresetSearchProviderTests {
    private let account = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.acme.test")!, displayName: "GitLab")

    @Test("a provider without preset search answers every account with its plain capabilities")
    func capabilitiesDefault() {
        let provider = PlainProvider()
        #expect(provider.capabilities(for: account) == provider.capabilities)
        #expect(!provider.capabilities(for: account).presetSearch)
    }

    @Test("capabilities created without a word about preset search have none")
    func capabilityDefaultsToOff() {
        let capabilities = ProviderCapabilities(
            pullRequestTerm: "Pull request", pullRequestAbbreviation: "PR", supportsOrganizationSources: true,
            supportsGroupSources: false, resolvesTeamReviewRequests: true, hostName: "GitHub", fetchesItemDetail: true
        )
        #expect(!capabilities.presetSearch)
    }

    @Test("a provider without preset search refuses one as unsupported")
    func fetchDefaultThrows() async {
        let search = PresetSearch(filter: .any, repositories: nil, sort: .lastActivity, kinds: [.pullRequest])
        await #expect(throws: ProviderError.unsupported("Preset search")) {
            _ = try await PlainProvider().fetchPresetItems(account: account, token: "t", search: search)
        }
    }
}

@Suite("Preset search from a preset")
struct PresetSearchFromPresetTests {
    private let acme = UUID()
    private let other = UUID()

    @Test("carries the preset's filter, sort and kinds")
    func carriesSelection() throws {
        let filter = ItemFilter(relations: [.assignedToMe], labelsAny: ["bug"])
        let preset = Preset(name: "Bugs", kinds: [.pullRequest, .issue], filter: filter, sort: .oldestCreated)
        let search = try #require(PresetSearch(preset: preset, accountID: acme))
        #expect(search == PresetSearch(filter: filter, repositories: nil, sort: .oldestCreated, kinds: [.pullRequest, .issue]))
    }

    @Test("a preset of every account searches all sources of each")
    func unscoped() throws {
        let search = try #require(PresetSearch(preset: Preset(name: "All"), accountID: acme))
        #expect(search.repositories == nil)
    }

    @Test("a scope of the account without repositories searches all its sources")
    func wholeAccount() throws {
        let preset = Preset(name: "Acme", scopes: [PresetScope(accountID: acme)])
        let search = try #require(PresetSearch(preset: preset, accountID: acme))
        #expect(search.repositories == nil)
    }

    @Test("a scope with repositories searches only those")
    func repositories() throws {
        let preset = Preset(name: "App", scopes: [PresetScope(accountID: acme, repositories: ["acme/app", "acme/api"]),
                                                  PresetScope(accountID: other, repositories: ["octo-org/site"])])
        let search = try #require(PresetSearch(preset: preset, accountID: acme))
        #expect(search.repositories == ["acme/app", "acme/api"])
    }

    @Test("two scopes of one account search what either covers, as the local filter does")
    func twoScopes() throws {
        let narrow = Preset(name: "Two", scopes: [PresetScope(accountID: acme, repositories: ["acme/app"]),
                                                  PresetScope(accountID: acme, repositories: ["acme/api"])])
        #expect(try #require(PresetSearch(preset: narrow, accountID: acme)).repositories == ["acme/app", "acme/api"])
        let wide = Preset(name: "Wide", scopes: [PresetScope(accountID: acme, repositories: ["acme/app"]),
                                                 PresetScope(accountID: acme)])
        #expect(try #require(PresetSearch(preset: wide, accountID: acme)).repositories == nil)
    }

    @Test("a preset scoped to other accounts has no search in this one")
    func otherAccount() {
        let preset = Preset(name: "Elsewhere", scopes: [PresetScope(accountID: other)])
        #expect(PresetSearch(preset: preset, accountID: acme) == nil)
    }
}
