import Foundation
import Testing
@testable import GitwallCore

/// A provider that implements only what every provider must: it cannot look up the state of single items.
private struct ListOnlyProvider: GitProvider {
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

@Suite("Item state lookup at the provider")
struct ItemStateLookupTests {
    @Test("a provider without an item state lookup refuses one as unsupported")
    func defaultThrows() async {
        let account = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.acme.test")!, displayName: "GitLab")
        let item = WorkItem(accountID: account.id, kind: .pullRequest, repoFullName: "acme/app", number: 1, title: "Change",
                            url: URL(string: "https://gitlab.acme.test/acme/app/-/merge_requests/1")!,
                            author: UserRef(login: "alice"), createdAt: Date(timeIntervalSince1970: 0),
                            updatedAt: Date(timeIntervalSince1970: 0))
        await #expect(throws: ProviderError.unsupported("Item state lookup")) {
            _ = try await ListOnlyProvider().fetchItemStates(account: account, token: "t", items: [item])
        }
    }
}
