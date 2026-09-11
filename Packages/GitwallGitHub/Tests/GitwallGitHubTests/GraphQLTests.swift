import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!

@Suite("GraphQL fetchItems")
struct GraphQLFetchTests {
    private func account(_ sources: [RepoSource], nativeQuery: String? = nil) -> Account {
        Account(kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "prokopsimek"), nativeQuery: nativeQuery, sources: sources)
    }

    @Test("maps the captured repository fixture into work items")
    func mapsRepositoryFixture() async throws {
        let emptyPage = #"{"data":{"r0":{"nameWithOwner":"apple/swift","pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#
        let transport = StubTransport([.json(try Fixtures.data("graphql_repository_apple_swift.json")), .json(emptyPage), .json(emptyPage)])
        let items = try await GitHubProvider(transport: transport).fetchItems(
            account: account([.repository(fullName: "apple/swift")]), token: "t", kinds: [.pullRequest, .issue]
        )

        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.repoFullName == "apple/swift" || $0.repoFullName == "swiftlang/swift" })
        let prs = items.filter { $0.kind == .pullRequest }
        #expect(!prs.isEmpty)
        #expect(prs.allSatisfy { $0.reviewState != nil && $0.ciState != nil && $0.mergeState != nil })
        #expect(prs.allSatisfy { $0.url.absoluteString.contains("/pull/") })
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        let query = try await transport.graphQLQuery(at: 0)
        #expect(query.contains("r0: repository(owner: \"apple\", name: \"swift\")"))
        #expect(query.contains("pullRequests(states: OPEN, first: 50"))
        #expect(query.contains("issues(states: OPEN, first: 50"))
    }

    @Test("only requested connections are queried")
    func kindsSelectConnections() async throws {
        let transport = StubTransport([.json(#"{"data":{"r0":{"nameWithOwner":"a/b","pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#)])
        _ = try await GitHubProvider(transport: transport).fetchItems(account: account([.repository(fullName: "a/b")]), token: "t", kinds: [.pullRequest])
        let query = try await transport.graphQLQuery(at: 0)
        #expect(query.contains("pullRequests("))
        #expect(!query.contains("issues("))
    }

    @Test("repositories are batched 15 per request with sequential aliases")
    func batching() async throws {
        let transport = StubTransport()
        await transport.enqueue([.json(#"{"data":{}}"#), .json(#"{"data":{}}"#)])
        let sources = (0..<20).map { RepoSource.repository(fullName: "org/repo\($0)") }
        _ = try await GitHubProvider(transport: transport).fetchItems(account: account(sources), token: "t", kinds: [.pullRequest])

        #expect(await transport.requests.count == 2)
        let first = try await transport.graphQLQuery(at: 0)
        let second = try await transport.graphQLQuery(at: 1)
        #expect(first.contains("r14: repository(owner: \"org\", name: \"repo14\")"))
        #expect(!first.contains("r15:"))
        #expect(second.contains("r0: repository(owner: \"org\", name: \"repo15\")"))
        #expect(second.contains("r4: repository(owner: \"org\", name: \"repo19\")"))
    }

    @Test("a repository that cannot be resolved is skipped, the rest is kept")
    func notFoundTolerance() async throws {
        let transport = StubTransport([.json(try Fixtures.data("graphql_repository_not_found.json"))])
        let items = try await GitHubProvider(transport: transport).fetchItems(
            account: account([.repository(fullName: "swiftlang/swift"), .repository(fullName: "prokopsimek/definitely-does-not-exist-xyz")]),
            token: "t", kinds: [.pullRequest]
        )
        #expect(items.isEmpty)
    }

    @Test("invalid repository names never reach the API")
    func invalidNames() async throws {
        let transport = StubTransport()
        let items = try await GitHubProvider(transport: transport).fetchItems(
            account: account([.repository(fullName: "no-slash"), .repository(fullName: "a/b/c"), .repository(fullName: "a/b\"){")]),
            token: "t", kinds: [.pullRequest]
        )
        #expect(items.isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test("follows per-repository pagination up to three extra pages")
    func repositoryPagination() async throws {
        func page(_ n: Int, more: Bool) -> String {
            #"{"data":{"r0":{"nameWithOwner":"a/b","pullRequests":{"pageInfo":{"hasNextPage":\#(more),"endCursor":"c\#(n)"},"nodes":[{"number":\#(n),"title":"PR \#(n)","url":"https://github.com/a/b/pull/\#(n)","isDraft":false,"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","repository":{"nameWithOwner":"a/b"}}]}}}}"#
        }
        let transport = StubTransport([.json(page(1, more: true)), .json(page(2, more: true)), .json(page(3, more: true)), .json(page(4, more: true)), .json(page(5, more: true))])
        let items = try await GitHubProvider(transport: transport).fetchItems(account: account([.repository(fullName: "a/b")]), token: "t", kinds: [.pullRequest])
        #expect(items.map(\.number) == [1, 2, 3, 4])
        #expect(await transport.requests.count == 4)
        let query = try await transport.graphQLQuery(at: 1)
        #expect(query.contains("after: \"c1\""))
    }

    @Test("organizations use search with the composed query and native query appended")
    func organizationSearch() async throws {
        let transport = StubTransport([
            .json(try Fixtures.data("graphql_search_org_apple_prs.json")),
            .json(try Fixtures.data("graphql_search_org_apple_prs.json")),
            .json(#"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#),
        ])
        let items = try await GitHubProvider(transport: transport).fetchItems(
            account: account([.organization(login: "apple")], nativeQuery: "label:bug"), token: "t", kinds: [.pullRequest]
        )
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.kind == .pullRequest })
        #expect(try await transport.graphQLVariable("q", at: 0) == "org:apple is:pr is:open archived:false sort:updated-desc label:bug")
        #expect(try await transport.graphQLVariable("after", at: 0) == nil)
        #expect(try await transport.graphQLVariable("after", at: 1) == "Y3Vyc29yOjM=")
        // Fixture pages repeat, so the third page is the empty one; max three pages are fetched.
        #expect(await transport.requests.count == 3)
    }

    @Test("issues from search map without pull request fields")
    func organizationIssues() async throws {
        let transport = StubTransport([.json(try Fixtures.data("graphql_search_org_apple_issues.json")), .json(#"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#), .json(#"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#)])
        let items = try await GitHubProvider(transport: transport).fetchItems(account: account([.organization(login: "apple")]), token: "t", kinds: [.issue])
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.kind == .issue && $0.reviewState == nil && $0.ciState == nil })
        #expect(try await transport.graphQLVariable("q", at: 0)?.contains("is:issue") == true)
    }

    @Test("over-long search queries are rejected before hitting the API")
    func searchLengthGuard() async throws {
        let transport = StubTransport()
        let long = String(repeating: "label:x ", count: 40)
        await #expect(throws: ProviderError.self) {
            _ = try await GitHubProvider(transport: transport).fetchItems(account: account([.organization(login: "apple")], nativeQuery: long), token: "t", kinds: [.pullRequest])
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("GraphQL top-level errors without data map to provider errors")
    func graphQLErrors() async throws {
        let rateLimited = StubTransport([.json(#"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)])
        await #expect(throws: ProviderError.rateLimited(resetAt: nil)) {
            _ = try await GitHubProvider(transport: rateLimited).fetchItems(account: account([.repository(fullName: "a/b")]), token: "t", kinds: [.pullRequest])
        }
        let forbidden = StubTransport([.json(#"{"errors":[{"type":"INSUFFICIENT_SCOPES","message":"needs repo"}]}"#)])
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await GitHubProvider(transport: forbidden).fetchItems(account: account([.repository(fullName: "a/b")]), token: "t", kinds: [.pullRequest])
        }
    }

    @Test("duplicates across sources are removed")
    func dedup() async throws {
        let node = "{\"number\":1,\"title\":\"PR\",\"url\":\"https://github.com/a/b/pull/1\",\"isDraft\":false,\"createdAt\":\"2026-09-01T00:00:00Z\",\"updatedAt\":\"2026-09-01T00:00:00Z\",\"repository\":{\"nameWithOwner\":\"a/b\"}}"
        let repoResponse = "{\"data\":{\"r0\":{\"nameWithOwner\":\"a/b\",\"pullRequests\":{\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[" + node + "]}}}}"
        let searchNode = node.replacingOccurrences(of: "{\"number\"", with: "{\"__typename\":\"PullRequest\",\"number\"")
        let searchResponse = "{\"data\":{\"search\":{\"issueCount\":1,\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[" + searchNode + "]}}}"
        let transport = StubTransport([.json(repoResponse), .json(searchResponse)])
        let items = try await GitHubProvider(transport: transport).fetchItems(
            account: account([.repository(fullName: "a/b"), .organization(login: "a")]), token: "t", kinds: [.pullRequest]
        )
        #expect(items.count == 1)
    }
}

@Suite("GraphQL mapping")
struct GraphQLMappingTests {
    @Test("review state falls back to latest reviews and requests")
    func reviewFallbacks() {
        #expect(GraphQLMapping.reviewState(decision: "APPROVED", reviews: [], hasRequests: false) == .approved)
        #expect(GraphQLMapping.reviewState(decision: "CHANGES_REQUESTED", reviews: [], hasRequests: false) == .changesRequested)
        #expect(GraphQLMapping.reviewState(decision: "REVIEW_REQUIRED", reviews: [], hasRequests: false) == .pending)
        #expect(GraphQLMapping.reviewState(decision: nil, reviews: [.init(state: "APPROVED", author: nil)], hasRequests: false) == .approved)
        #expect(GraphQLMapping.reviewState(decision: nil, reviews: [.init(state: "CHANGES_REQUESTED", author: nil)], hasRequests: true) == .changesRequested)
        #expect(GraphQLMapping.reviewState(decision: nil, reviews: [], hasRequests: true) == .pending)
        #expect(GraphQLMapping.reviewState(decision: nil, reviews: [], hasRequests: false) == ReviewState.none)
    }

    @Test("CI and merge states")
    func states() {
        #expect(GraphQLMapping.ciState("SUCCESS") == .success)
        #expect(GraphQLMapping.ciState("FAILURE") == .failure)
        #expect(GraphQLMapping.ciState("ERROR") == .failure)
        #expect(GraphQLMapping.ciState("PENDING") == .running)
        #expect(GraphQLMapping.ciState("EXPECTED") == .running)
        #expect(GraphQLMapping.ciState(nil) == CIState.none)
        #expect(GraphQLMapping.mergeState("MERGEABLE") == .clean)
        #expect(GraphQLMapping.mergeState("CONFLICTING") == .conflict)
        #expect(GraphQLMapping.mergeState("UNKNOWN") == .unknown)
        #expect(GraphQLMapping.mergeState(nil) == .unknown)
    }

    @Test("team review requests are ignored, user requests kept, ghost authors tolerated")
    func requestedReviewers() throws {
        let json = #"{"number":9,"title":"T","url":"https://github.com/a/b/pull/9","isDraft":true,"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z","author":null,"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","slug":"core","name":"Core"}},{"requestedReviewer":{"__typename":"User","login":"alice","name":"Alice","avatarUrl":"https://a/alice"}},{"requestedReviewer":null}]},"labels":{"nodes":[{"name":"bug","color":"D73A4A"}]},"repository":{"nameWithOwner":"a/b"}}"#
        let node = try GitHubClient.decoder.decode(ItemNode.self, from: Data(json.utf8))
        let item = GraphQLMapping.workItem(node, kind: .pullRequest, accountID: UUID(), fallbackRepository: "x/y")
        #expect(item.requestedReviewers.map(\.login) == ["alice"])
        #expect(item.author.login == "ghost")
        #expect(item.isDraft)
        #expect(item.labels.first?.colorHex == "D73A4A")
        #expect(item.reviewState == .pending)
        #expect(item.repoFullName == "a/b")
    }
}

@Suite("Integration", .enabled(if: ProcessInfo.processInfo.environment["GITWALL_GITHUB_TOKEN"] != nil))
struct GitHubIntegrationTests {
    private var token: String { ProcessInfo.processInfo.environment["GITWALL_GITHUB_TOKEN"] ?? "" }

    @Test("verify returns the token owner")
    func verify() async throws {
        let me = try await GitHubProvider().verify(baseURL: github, token: token)
        #expect(!me.login.isEmpty)
    }

    @Test("fetches open pull requests of apple/swift with states")
    func fetch() async throws {
        let account = Account(kind: .github, baseURL: github, displayName: "GitHub", sources: [.repository(fullName: "apple/swift")])
        let items = try await GitHubProvider().fetchItems(account: account, token: token, kinds: [.pullRequest])
        #expect(items.count > 0)
        #expect(items.allSatisfy { $0.reviewState != nil && $0.ciState != nil && $0.mergeState != nil })
    }

    @Test("discovers organizations and repositories")
    func discover() async throws {
        let provider = GitHubProvider()
        let orgs = try await provider.discoverContainers(baseURL: github, token: token)
        let repos = try await provider.discoverRepositories(baseURL: github, token: token, query: nil)
        print("integration: \(repos.count) repositories, organizations: \(orgs.map(\.id).joined(separator: ", "))")
        #expect(!repos.isEmpty)
    }

    /// Checks a repository the token can only reach with its own permissions, such as a private repository and a
    /// fine-grained token. Pick one with open pull requests or issues:
    ///
    ///     GITWALL_GITHUB_TOKEN=github_pat_… GITWALL_GITHUB_REPO=owner/private-repo \
    ///         swift test --package-path Packages/GitwallGitHub --filter Integration
    @Test(
        "fetches pull requests and issues of GITWALL_GITHUB_REPO",
        .enabled(if: ProcessInfo.processInfo.environment["GITWALL_GITHUB_REPO"] != nil)
    )
    func fetchConfiguredRepository() async throws {
        let repo = ProcessInfo.processInfo.environment["GITWALL_GITHUB_REPO"] ?? ""
        let account = Account(kind: .github, baseURL: github, displayName: "GitHub", sources: [.repository(fullName: repo)])
        let items = try await GitHubProvider().fetchItems(account: account, token: token, kinds: [.pullRequest, .issue])
        let pulls = items.filter { $0.kind == .pullRequest }
        let withCI = pulls.filter { $0.ciState != CIState.none }
        print("integration: \(repo): \(pulls.count) pull requests (\(withCI.count) with CI state), \(items.count - pulls.count) issues")
        #expect(!items.isEmpty, "The token cannot read \(repo), or it has no open pull requests or issues")
    }
}
