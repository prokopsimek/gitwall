import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!
private let enterprise = URL(string: "https://ghe.acme.test")!

private func account(_ sources: [RepoSource], baseURL: URL = github) -> Account {
    Account(kind: .github, baseURL: baseURL, displayName: "GitHub", me: UserRef(login: "bob"), sources: sources)
}

private func search(
    _ kinds: Set<ItemKind>, filter: ItemFilter = .any, repositories: Set<String>? = nil, sort: GitwallCore.SortOrder = .lastActivity
) -> PresetSearch {
    PresetSearch(filter: filter, repositories: repositories, sort: sort, kinds: kinds)
}

/// Answers in the shape GitHub gives a `search`, in the shape of the captured fixtures, scripted for tests that page or split.
private enum SearchAnswer {
    static func page(_ nodes: [String], issueCount: Int, endCursor: String? = nil, hasNextPage: Bool = false) -> StubTransport.Response {
        let cursor = endCursor.map { "\"\($0)\"" } ?? "null"
        return .json(#"{"data":{"rateLimit":{"cost":1,"remaining":4990,"resetAt":"2026-11-19T13:00:00Z"},"search":{"issueCount":\#(issueCount),"pageInfo":{"hasNextPage":\#(hasNextPage),"endCursor":\#(cursor)},"nodes":[\#(nodes.joined(separator: ","))]}}}"#)
    }

    static let empty = page([], issueCount: 0)

    static func node(_ kind: ItemKind, repo: String, number: Int) -> String {
        let author = #""author":{"login":"alice","avatarUrl":"https://avatars.githubusercontent.com/u/1?v=4","name":"Alice"}"#
        let common = #""number":\#(number),"createdAt":"2026-11-01T09:00:00Z","updatedAt":"2026-11-18T09:00:00Z",\#(author),"labels":{"nodes":[]},"assignees":{"nodes":[]},"milestone":null,"comments":{"totalCount":0},"repository":{"nameWithOwner":"\#(repo)"}"#
        switch kind {
        case .pullRequest:
            return #"{"__typename":"PullRequest","id":"PR_kwDOAcme\#(number)","title":"Change \#(number)","url":"https://github.com/\#(repo)/pull/\#(number)","isDraft":false,\#(common),"reviewDecision":null,"mergeable":"MERGEABLE","additions":1,"deletions":1,"reviewRequests":{"nodes":[]},"latestReviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}"#
        case .issue:
            return #"{"__typename":"Issue","id":"I_kwDOAcme\#(number)","title":"Report \#(number)","url":"https://github.com/\#(repo)/issues/\#(number)",\#(common)}"#
        }
    }
}

/// The cursor GitHub would hand out after page `index`, and the page it leads to.
private func cursor(after index: Int) -> String { "c\(index)" }
private func pageIndex(after cursor: String?) -> Int {
    guard let cursor else { return 0 }
    return Int(cursor.dropFirst())! + 1
}

// MARK: - What is sent

@Suite("Preset search: what is sent")
struct PresetFetchRequestTests {
    @Test("one kind sends one ISSUE_ADVANCED search, 25 pull requests or 100 issues per page",
          arguments: [(ItemKind.pullRequest, 25, "is:pr"), (.issue, 100, "is:issue")])
    func oneKind(kind: ItemKind, pageSize: Int, kindTerm: String) async throws {
        let transport = ScriptedTransport { _ in SearchAnswer.empty }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([kind])
        )

        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://api.github.com/graphql")
        #expect(requests.first?.query.contains("search(query: $q, type: ISSUE_ADVANCED, first: \(pageSize), after: $after)") == true)
        #expect(requests.first?.variables == ["q": "\(kindTerm) is:open org:acme archived:false sort:updated-desc"])
        #expect(fetch == PresetFetch(items: [], totalCount: 0, isComplete: true, requests: 1))
    }

    @Test("a preset of both kinds sends one search per kind, each with its own page size")
    func bothKinds() async throws {
        let transport = ScriptedTransport { _ in SearchAnswer.empty }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest, .issue])
        )

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(fetch.requests == 2)
        let pulls = requests.filter { $0.variables["q"]?.hasPrefix("is:pr ") == true }
        let issues = requests.filter { $0.variables["q"]?.hasPrefix("is:issue ") == true }
        #expect(pulls.count == 1 && issues.count == 1)
        #expect(pulls.first?.query.contains("type: ISSUE_ADVANCED, first: 25,") == true)
        #expect(issues.first?.query.contains("type: ISSUE_ADVANCED, first: 100,") == true)
    }

    @Test("the account's sources go out as one OR group, before archived:false, the filter and the sort", arguments: [
        ([RepoSource.organization(login: "acme"), .repository(fullName: "octo-org/site")], "(org:acme OR repo:octo-org/site)"),
        ([RepoSource.repository(fullName: "acme/app"), .repository(fullName: "acme/api")], "(repo:acme/app OR repo:acme/api)"),
        ([RepoSource.organization(login: "acme"), .organization(login: "octo-org")], "(org:acme OR org:octo-org)"),
        ([RepoSource.repository(fullName: "acme/app")], "repo:acme/app"),
        // A GitLab group has no meaning on GitHub.
        ([RepoSource.organization(login: "acme"), .group(fullPath: "acme/web", includeSubgroups: true)], "org:acme"),
    ])
    func sources(sources: [RepoSource], expected: String) async throws {
        let transport = ScriptedTransport { _ in SearchAnswer.empty }
        _ = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account(sources), token: "t",
            search: search([.pullRequest], filter: ItemFilter(relations: [.assignedToMe]), sort: .oldestCreated)
        )

        #expect(await transport.requests.map { $0.variables["q"] } == [
            "is:pr is:open \(expected) archived:false assignee:@me sort:created-asc",
        ])
    }

    @Test("a scope with repositories searches those repositories instead of the account's sources")
    func scopeRepositories() async throws {
        let transport = ScriptedTransport { _ in SearchAnswer.empty }
        _ = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme"), .repository(fullName: "octo-org/site")]), token: "t",
            search: search([.issue], repositories: ["acme/app", "acme/api"])
        )

        #expect(await transport.requests.map { $0.variables["q"] } == [
            "is:issue is:open (repo:acme/api OR repo:acme/app) archived:false sort:updated-desc",
        ])
    }

    @Test("a kind the filter cannot match is not searched: no request, complete, nothing found", arguments: [
        ItemFilter(query: "is:issue label:bug"),
        ItemFilter(labelsAny: ["bug"], query: "mentions:x"),
        ItemFilter(query: "(label:bug"),
    ])
    func kindThatMatchesNothing(filter: ItemFilter) async throws {
        let transport = ScriptedTransport { _ in SearchAnswer.empty }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest], filter: filter)
        )

        #expect(await transport.requests.isEmpty)
        #expect(fetch == PresetFetch(items: [], totalCount: 0, isComplete: true, requests: 0))
    }

    @Test("of two kinds, one the filter cannot match is skipped and the other is searched")
    func oneKindMatchesNothing() async throws {
        let transport = ScriptedTransport { _ in
            SearchAnswer.page([SearchAnswer.node(.issue, repo: "acme/app", number: 1)], issueCount: 1)
        }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t",
            search: search([.pullRequest, .issue], filter: ItemFilter(query: "is:issue label:bug"))
        )

        #expect(await transport.requests.map { $0.variables["q"] } == [
            #"is:issue is:open org:acme archived:false label:"bug" sort:updated-desc"#,
        ])
        #expect(fetch.requests == 1)
        #expect(fetch.items.count == 1)
        #expect(fetch.totalCount == 1)
        #expect(fetch.isComplete)
    }

    struct NothingToSearch: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let sources: [RepoSource]
        var repositories: Set<String>?
        var kinds: Set<ItemKind> = [.pullRequest]
    }

    @Test("with nothing to search nothing is sent, and nothing can be missing", arguments: [
        NothingToSearch(testDescription: "an account without sources", sources: []),
        NothingToSearch(testDescription: "an account with no GitHub source", sources: [.group(fullPath: "acme", includeSubgroups: false)]),
        NothingToSearch(testDescription: "a scope of no repositories", sources: [.organization(login: "acme")], repositories: []),
        NothingToSearch(testDescription: "a preset of no kind", sources: [.organization(login: "acme")], kinds: []),
    ])
    func nothingToSearch(row: NothingToSearch) async throws {
        let transport = ScriptedTransport { _ in SearchAnswer.empty }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account(row.sources), token: "t", search: search(row.kinds, repositories: row.repositories)
        )

        #expect(await transport.requests.isEmpty)
        #expect(fetch == PresetFetch(items: [], totalCount: 0, isComplete: true, requests: 0))
    }
}

// MARK: - Length

@Suite("Preset search: GitHub's 4000-character limit")
struct PresetFetchLengthTests {
    @Test("sources too long for one search are split over several, each within the limit, and merged without duplicates")
    func splitsSources() async throws {
        // Every source term is about 50 characters, so the 200 repositories alone need more than two searches.
        let repositories = (0..<200).map { "acme/payments-service-with-a-long-name-\(String(format: "%03d", $0))" }
        let sources = [RepoSource.organization(login: "acme")] + repositories.map { RepoSource.repository(fullName: $0) }
        // GitHub answers each search with what its sources hold: a pull request per repository it names, and for
        // `org:acme` one from every repository of acme. So every repository outside that search turns up twice.
        @Sendable func found(by query: String) -> [String] {
            let terms = query.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
            return terms.contains("org:acme") ? repositories : terms.filter { $0.hasPrefix("repo:") }.map { String($0.dropFirst(5)) }
        }
        let transport = ScriptedTransport { request in
            let nodes = found(by: request.variables["q"] ?? "").map { SearchAnswer.node(.pullRequest, repo: $0, number: 1) }
            return SearchAnswer.page(nodes, issueCount: nodes.count)
        }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account(sources), token: "t", search: search([.pullRequest], filter: ItemFilter(labelsAny: ["bug"]))
        )

        let queries = await transport.requests.compactMap { $0.variables["q"] }
        #expect(queries.count >= 3)
        #expect(fetch.requests == queries.count)
        for query in queries {
            #expect(query.utf8.count <= 4000)
            #expect(query.hasPrefix("is:pr is:open "))
            #expect(query.hasSuffix(#" archived:false label:"bug" sort:updated-desc"#))
        }
        // Every source is searched exactly once.
        let searched = queries.flatMap { $0.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) } }
            .filter { $0.hasPrefix("repo:") || $0.hasPrefix("org:") }
        #expect(searched.sorted() == (["org:acme"] + repositories.map { "repo:\($0)" }).sorted())

        #expect(fetch.items.map(\.repoFullName).sorted() == repositories)
        #expect(Set(fetch.items.map(\.id)).count == fetch.items.count)
        // GitHub's counts added up, duplicates and all.
        #expect(fetch.totalCount == queries.map { found(by: $0).count }.reduce(0, +))
        #expect(fetch.totalCount > repositories.count)
        #expect(fetch.isComplete)
    }

    struct TooLong: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let labelsNone: [String]
        let kept: String
    }

    @Test("a filter too long beside one source leaves out its longest terms first, but never kind, state, source or archived:false",
          arguments: [
              TooLong(testDescription: "terms of 3009 and 1209 characters cannot both fit; without the longest the rest can",
                      labelsNone: [String(repeating: "l", count: 3000), String(repeating: "m", count: 1200), "wip"],
                      kept: #"author:@me -label:"\#(String(repeating: "m", count: 1200))" -label:"wip""#),
              TooLong(testDescription: "a single term that alone is too long goes, and the search still runs",
                      labelsNone: [String(repeating: "l", count: 4100)], kept: "author:@me"),
          ])
    func dropsLongestTerms(row: TooLong) async throws {
        let transport = ScriptedTransport { _ in SearchAnswer.empty }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t",
            search: search([.pullRequest], filter: ItemFilter(relations: [.authoredByMe], labelsNone: row.labelsNone))
        )

        let queries = await transport.requests.compactMap { $0.variables["q"] }
        #expect(queries == ["is:pr is:open org:acme archived:false \(row.kept) sort:updated-desc"])
        #expect(queries.allSatisfy { $0.utf8.count <= 4000 })
        #expect(fetch.isComplete)
    }
}

// MARK: - Paging

@Suite("Preset search: paging")
struct PresetFetchPagingTests {
    /// Full pages of `kind` that GitHub counts 1500 of. When `endsAtTheCap`, the page that reaches 1000 results says it
    /// is the last, as GitHub's search does at its cap; otherwise every page claims another, so only the cap can end it.
    private func pages(_ kind: ItemKind, pageSize: Int, endsAtTheCap: Bool) -> ScriptedTransport {
        ScriptedTransport { request in
            let index = pageIndex(after: request.variables["after"])
            let nodes = (0..<pageSize).map { SearchAnswer.node(kind, repo: "acme/app", number: index * pageSize + $0 + 1) }
            let last = endsAtTheCap && (index + 1) * pageSize >= 1000
            return SearchAnswer.page(nodes, issueCount: 1500, endCursor: cursor(after: index), hasNextPage: !last)
        }
    }

    @Test("paging stops at 1000 results, after 40 pages of 25 pull requests or 10 of 100 issues, and says it is incomplete",
          arguments: [(ItemKind.pullRequest, 25, 40), (.issue, 100, 10)], [false, true])
    func stopsAtTheCap(paging: (kind: ItemKind, pageSize: Int, pages: Int), endsAtTheCap: Bool) async throws {
        let (kind, pageSize, pages) = paging
        let transport = self.pages(kind, pageSize: pageSize, endsAtTheCap: endsAtTheCap)
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([kind])
        )

        let requests = await transport.requests
        #expect(requests.count == pages)
        #expect(fetch.requests == pages)
        #expect(requests.allSatisfy { $0.query.contains("type: ISSUE_ADVANCED, first: \(pageSize), after: $after") })
        #expect(requests.map { $0.variables["after"] } == [nil] + (0..<(pages - 1)).map { cursor(after: $0) })
        #expect(Set(requests.map { $0.variables["q"] }).count == 1)
        #expect(fetch.items.count == 1000)
        #expect(Set(fetch.items.map(\.id)).count == 1000)
        #expect(fetch.totalCount == 1500)
        #expect(!fetch.isComplete)
    }

    @Test("a search that ends before 1000 results is complete and carries GitHub's count")
    func endsBeforeTheCap() async throws {
        // 25, 25 and 10 pull requests; the third page is the last.
        let transport = ScriptedTransport { request in
            let index = pageIndex(after: request.variables["after"])
            let size = index < 2 ? 25 : 10
            let nodes = (0..<size).map { SearchAnswer.node(.pullRequest, repo: "acme/app", number: index * 25 + $0 + 1) }
            return SearchAnswer.page(nodes, issueCount: 60, endCursor: cursor(after: index), hasNextPage: index < 2)
        }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest])
        )

        #expect(await transport.requests.map { $0.variables["after"] } == [nil, cursor(after: 0), cursor(after: 1)])
        #expect(fetch.requests == 3)
        #expect(fetch.items.count == 60)
        #expect(fetch.totalCount == 60)
        #expect(fetch.isComplete)
    }

    @Test("the counts of both kinds add up, and one search that reached the cap makes the fetch incomplete")
    func totalsAcrossKinds() async throws {
        let transport = ScriptedTransport { request in
            guard request.variables["q"]?.hasPrefix("is:issue ") == true else {
                return SearchAnswer.page((1...5).map { SearchAnswer.node(.pullRequest, repo: "acme/app", number: $0) }, issueCount: 5)
            }
            let index = pageIndex(after: request.variables["after"])
            let nodes = (0..<100).map { SearchAnswer.node(.issue, repo: "acme/app", number: index * 100 + $0 + 1) }
            return SearchAnswer.page(nodes, issueCount: 2400, endCursor: cursor(after: index), hasNextPage: true)
        }
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest, .issue])
        )

        #expect(await transport.requests.count == 11)
        #expect(fetch.requests == 11)
        #expect(fetch.items.count == 1005)
        #expect(fetch.totalCount == 2405)
        #expect(!fetch.isComplete)
    }

    /// Two pages that GitHub says follow each other; `first` is page one, page two holds one covered pull request.
    private func twoPages(first: [String]) -> ScriptedTransport {
        ScriptedTransport { request in
            if request.variables["after"] == nil {
                return SearchAnswer.page(first, issueCount: 30, endCursor: cursor(after: 0), hasNextPage: true)
            }
            return SearchAnswer.page([SearchAnswer.node(.pullRequest, repo: "acme/app", number: 99)], issueCount: 30,
                                     endCursor: cursor(after: 1), hasNextPage: false)
        }
    }

    @Test("pages that hold only items of the sources are read to the end, and the result is complete")
    func coveredPagesArePagedNormally() async throws {
        let transport = twoPages(first: [SearchAnswer.node(.pullRequest, repo: "acme/api", number: 1)])
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest])
        )

        #expect(await transport.requests.count == 2)
        #expect(fetch.items.map(\.number) == [1, 99])
        #expect(fetch.isComplete)
    }

    @Test("a page with an item outside the sources stops the search: one request, the covered items kept, incomplete")
    func stopsAtAnItemOutsideTheSources() async throws {
        let transport = twoPages(first: [
            SearchAnswer.node(.pullRequest, repo: "acme/app", number: 1),
            SearchAnswer.node(.pullRequest, repo: "globex/tools", number: 2),
        ])
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest])
        )

        #expect(await transport.requests.count == 1)
        #expect(fetch.requests == 1)
        #expect(fetch.items.map(\.number) == [1])
        #expect(fetch.totalCount == 30)
        #expect(!fetch.isComplete)
    }

    @Test("an item of the other kind outside the sources is ignored, and paging goes on")
    func otherKindOutsideTheSourcesIsIgnored() async throws {
        let transport = twoPages(first: [
            SearchAnswer.node(.pullRequest, repo: "acme/app", number: 1),
            SearchAnswer.node(.issue, repo: "globex/tools", number: 2),
        ])
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest])
        )

        #expect(await transport.requests.count == 2)
        #expect(fetch.items.map(\.number) == [1, 99])
        #expect(fetch.isComplete)
    }

    @Test("an item without a repository is not outside the sources: it is dropped and paging goes on")
    func itemWithoutRepositoryIsNotOutside() async throws {
        let nameless = SearchAnswer.node(.pullRequest, repo: "acme/app", number: 2)
            .replacingOccurrences(of: #""repository":{"nameWithOwner":"acme/app"}"#, with: #""repository":null"#)
        #expect(nameless.contains(#""repository":null"#))
        let transport = twoPages(first: [SearchAnswer.node(.pullRequest, repo: "acme/app", number: 1), nameless])
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest])
        )

        #expect(await transport.requests.count == 2)
        #expect(fetch.items.map(\.number) == [1, 99])
        #expect(fetch.isComplete)
    }

    @Test("a page GitHub answered with 502 is asked again, and both attempts count as requests")
    func gatewayErrorCounts() async throws {
        let sleeps = SleepRecorder()
        let transport = StubTransport([
            .json(#"{"message":"Bad gateway"}"#, status: 502),
            SearchAnswer.page([SearchAnswer.node(.pullRequest, repo: "acme/app", number: 1)], issueCount: 1),
        ])
        let fetch = try await GitHubProvider(transport: transport, sleep: sleeps.sleep).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest])
        )

        #expect(await transport.requests.count == 2)
        #expect(fetch.requests == 2)
        #expect(fetch.items.map(\.number) == [1])
        #expect(await sleeps.delays == [.seconds(1)])
    }
}

// MARK: - What is kept

@Suite("Preset search: what is kept")
struct PresetFetchItemsTests {
    /// Only the team lookup has it; `viewer {` alone also matches `requestedReviewer {` in the pull request fragment.
    private static let teamLookup = "teams(first: 100, role: MEMBER)"
    private static let teams = #"{"data":{"viewer":{"organizations":{"nodes":[{"login":"\#(Captured.owner)","teams":{"nodes":[{"slug":"platform"}]}}]}}}}"#

    private func transport(prs: String, issues: String) throws -> RoutingTransport {
        RoutingTransport([
            ("fragment PR on PullRequest", .json(prs)),
            ("fragment Issue on Issue", .json(issues)),
            (Self.teamLookup, .json(Self.teams)),
        ])
    }

    /// The captured pages with some nodes moved to other repositories, which the public repository has none of: the
    /// first two pull requests and the first two issues go to a repository of the same owner in other letter case, to a
    /// source that is a single repository, to a repository that is nobody's source; the rest stay.
    private func moved() throws -> (prs: String, issues: String, prNumbers: [Int], issueNumbers: [Int]) {
        let prNodes = try Captured.searchNodes("graphql_preset_search_prs.json")
        let issueNodes = try Captured.searchNodes("graphql_preset_search_issues.json")
        let prRepositories = ["PROKOPSIMEK/api", "elsewhere/site", "elsewhere/other", "unrelated/tools"]
        let issueRepositories = ["elsewhere/site", "unrelated/tools"]
        let prs = prNodes.enumerated().map { index, node in
            index < prRepositories.count ? Captured.with(node, ["repository": Captured.repository(named: prRepositories[index])]) : node
        }
        let issues = issueNodes.enumerated().map { index, node in
            index < issueRepositories.count ? Captured.with(node, ["repository": Captured.repository(named: issueRepositories[index])]) : node
        }
        return (try Captured.searchAnswer("graphql_preset_search_prs.json", nodes: prs),
                try Captured.searchAnswer("graphql_preset_search_issues.json", nodes: issues),
                prNodes.compactMap { $0["number"] as? Int }, issueNodes.compactMap { $0["number"] as? Int })
    }

    @Test("the captured pages: every item is kept, as a source of its owner, with GitHub's count")
    func capturedPagesAreKept() async throws {
        let transport = try transport(prs: try Fixtures.string("graphql_preset_search_prs.json"),
                                      issues: try Fixtures.string("graphql_preset_search_issues.json"))
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: Captured.owner)]), token: "t", search: search([.pullRequest, .issue])
        )

        let prs = try Captured.searchNodes("graphql_preset_search_prs.json")
        let issues = try Captured.searchNodes("graphql_preset_search_issues.json")
        #expect(fetch.items.count == prs.count + issues.count)
        #expect(Set(fetch.items.map(\.repoFullName)) == [Captured.repository])
        #expect(fetch.totalCount == prs.count + issues.count)
        #expect(fetch.isComplete)
    }

    @Test("derived from the captured pages with items moved to other repositories: strangers are dropped; an organisation matches its owner in any case")
    func strangersAreDropped() async throws {
        let moved = try moved()
        let fetch = try await GitHubProvider(transport: try transport(prs: moved.prs, issues: moved.issues)).fetchPresetItems(
            account: account([.organization(login: Captured.owner), .repository(fullName: "elsewhere/site")]), token: "t",
            search: search([.pullRequest])
        )

        // Only the first four pull requests moved: the other repository of the owner in capital letters and elsewhere/site
        // stay; elsewhere/other and unrelated/tools are nobody's.
        let kept = Set(moved.prNumbers.prefix(2)).union(moved.prNumbers.dropFirst(4))
        #expect(Set(fetch.items.map(\.number)) == kept)
        #expect(fetch.items.contains { $0.repoFullName == "PROKOPSIMEK/api" })
        #expect(fetch.items.contains { $0.repoFullName == "elsewhere/site" })
        #expect(!fetch.items.contains { $0.repoFullName == "elsewhere/other" || $0.repoFullName == "unrelated/tools" })
        // GitHub's own count, strangers and all.
        #expect(fetch.totalCount == moved.prNumbers.count)
        #expect(fetch.isComplete)
    }

    @Test("derived with an issue in another repository: a scope keeps only its repositories, even when GitHub answers with more")
    func scopeKeepsItsRepositories() async throws {
        let moved = try moved()
        let scoped = account([.organization(login: Captured.owner)])
        let fetch = try await GitHubProvider(transport: try transport(prs: moved.prs, issues: moved.issues)).fetchPresetItems(
            account: scoped, token: "t", search: search([.issue], repositories: ["elsewhere/site"])
        )

        // The owner's repository is the account's, but not the scope's.
        let number = try #require(moved.issueNumbers.first)
        #expect(fetch.items.map(\.id) == [WorkItem.makeID(accountID: scoped.id, repoFullName: "elsewhere/site", number: number, kind: .issue)])
    }

    @Test("the captured nodes map as in the organization search: a pull request keeps its pull request fields, an issue carries none")
    func mapsLikeTheSearch() async throws {
        let prs = try Captured.searchNodes("graphql_preset_search_prs.json")
        let issues = try Captured.searchNodes("graphql_preset_search_issues.json")
        let transport = try transport(prs: try Fixtures.string("graphql_preset_search_prs.json"),
                                      issues: try Fixtures.string("graphql_preset_search_issues.json"))
        let me = account([.organization(login: Captured.owner)])
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: me, token: "t", search: search([.pullRequest, .issue])
        )

        #expect(fetch.items.allSatisfy { $0.accountID == me.id })
        let node = try #require(prs.first { $0["number"] as? Int == 24 })
        let pull = try #require(fetch.items.first { $0.number == 24 && $0.kind == .pullRequest })
        #expect(pull.title == node["title"] as? String)
        #expect(pull.nodeID == node["id"] as? String)
        #expect(pull.additions == node["additions"] as? Int)
        #expect(pull.deletions == node["deletions"] as? Int)
        #expect(pull.requestedReviewers.isEmpty)
        #expect(pull.ciState == .success)
        #expect(!pull.isDraft)
        let issue = try #require(fetch.items.first { $0.number == 1 && $0.kind == .issue })
        let issueNode = try #require(issues.first { $0["number"] as? Int == 1 })
        #expect(issue.title == issueNode["title"] as? String)
        #expect(issue.reviewState == nil && issue.ciState == nil)
        #expect(issue.author.login == Captured.owner)
        #expect(Set(fetch.items.map(\.number)).isSuperset(of: [1, 2, 3, 4, 24]))

        // One search per kind, and no team request among the captured nodes, so no look at my teams.
        let queries = await transport.queries
        #expect(queries.count == 2)
        #expect(queries.filter { $0.contains(Self.teamLookup) }.isEmpty)
        #expect(fetch.requests == 2)
    }

    @Test("derived with a draft that conflicts and fails its checks, a deleted author and a team request: mapped, the team resolved to me, one team lookup")
    func mapsVariants() async throws {
        let prNodes = try Captured.searchNodes("graphql_preset_search_prs.json")
        let issueNodes = try Captured.searchNodes("graphql_preset_search_issues.json")
        let requested = Captured.with(try #require(prNodes.first { $0["number"] as? Int == 24 }),
                                      ["reviewRequests": Captured.teamReviewRequests(team: "platform", user: "carol")])
        let draft = Captured.with(try #require(prNodes.first { $0["number"] as? Int == 20 }), [
            "isDraft": true, "mergeable": "CONFLICTING",
            "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "FAILURE"]]]]],
        ])
        let ghost = Captured.with(try #require(issueNodes.first { $0["number"] as? Int == 3 }), ["author": NSNull()])
        let transport = try transport(prs: try Captured.searchAnswer("graphql_preset_search_prs.json", nodes: [requested, draft]),
                                      issues: try Captured.searchAnswer("graphql_preset_search_issues.json", nodes: [ghost]))
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account([.organization(login: Captured.owner)]), token: "t", search: search([.pullRequest, .issue])
        )

        let team = try #require(fetch.items.first { $0.number == 24 })
        #expect(team.requestedReviewers.map(\.login) == ["bob", "carol"])
        let conflict = try #require(fetch.items.first { $0.number == 20 })
        #expect(conflict.isDraft)
        #expect(conflict.mergeState == .conflict)
        #expect(conflict.ciState == .failure)
        #expect(fetch.items.first { $0.number == 3 }?.author.login == "ghost")
        #expect(Set(fetch.items.map(\.number)) == [24, 20, 3])
        let queries = await transport.queries
        #expect(queries.filter { $0.contains(Self.teamLookup) }.count == 1)
        #expect(fetch.requests == 3)
    }
}

// MARK: - Errors

@Suite("Preset search: errors")
struct PresetFetchErrorTests {
    private func fetch(_ answer: StubTransport.Response) async throws {
        _ = try await GitHubProvider(transport: StubTransport([answer])).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest])
        )
    }

    @Test("GraphQL errors in a 200 answer fail the search as they fail every query", arguments: [
        (#"{"data":null,"errors":[{"message":"Something went wrong while executing your query."}]}"#,
         ProviderError.server(status: 200, message: "Something went wrong while executing your query.")),
        (#"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#, ProviderError.rateLimited(resetAt: nil)),
        (#"{"errors":[{"type":"INSUFFICIENT_SCOPES","message":"needs repo"}]}"#, ProviderError.unauthorized),
    ])
    func graphQLErrors(body: String, expected: ProviderError) async {
        await #expect(throws: expected) { try await fetch(.json(body)) }
    }

    private func page(errors: String) -> StubTransport.Response {
        let node = SearchAnswer.node(.pullRequest, repo: "acme/app", number: 1)
        return .json(#"{"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(node),null]}},"errors":\#(errors)}"#)
    }

    @Test("a page with only FORBIDDEN errors beside its results stays complete and keeps its items")
    func forbiddenIsTolerated() async throws {
        let answer = page(errors: #"[{"type":"FORBIDDEN","path":["search","nodes",1],"message":"Resource protected by organization SAML enforcement."}]"#)
        let fetch = try await GitHubProvider(transport: StubTransport([answer])).fetchPresetItems(
            account: account([.organization(login: "acme")]), token: "t", search: search([.pullRequest])
        )

        #expect(fetch.items.count == 1)
        #expect(fetch.isComplete)
    }

    @Test("a page with any other error beside its results fails the search and returns nothing", arguments: [
        #"[{"type":"INTERNAL","message":"boom"}]"#,
        #"[{"type":"SERVICE_UNAVAILABLE","message":"boom"}]"#,
        #"[{"type":"FORBIDDEN","message":"saml"},{"type":"INTERNAL","message":"boom"}]"#,
    ])
    func otherErrorsFail(errors: String) async {
        await #expect(throws: ProviderError.server(status: 200, message: "A search page came with GraphQL errors beside its results.")) {
            try await fetch(page(errors: errors))
        }
    }

    @Test("an error without a type is a partial failure")
    func untypedFails() async {
        await #expect(throws: ProviderError.server(status: 200, message: "A search page came with GraphQL errors beside its results.")) {
            try await fetch(page(errors: #"[{"message":"Something went wrong."}]"#))
        }
    }

    @Test("the log line names the types of the errors and never their messages")
    func summary() throws {
        let errors = try JSONDecoder().decode([GraphQLError].self, from: Data(
            #"[{"type":"INTERNAL","message":"secret-login"},{"type":"FORBIDDEN","message":"x"},{"type":"INTERNAL","message":"y"},{"message":"z"}]"#.utf8
        ))

        #expect(errors.typeSummary == "4 GraphQL errors of types FORBIDDEN, INTERNAL, UNTYPED")
        #expect(!errors.typeSummary.contains("secret-login"))
    }

    @Test("a search GitHub rejects fails with the status it was rejected with", arguments: [400, 422])
    func rejected(status: Int) async {
        await #expect(throws: ProviderError.server(status: status, message: "Validation Failed")) {
            try await fetch(.json(#"{"message":"Validation Failed"}"#, status: status))
        }
    }
}

// MARK: - GitHub.com only

@Suite("Preset search: GitHub.com only")
struct PresetFetchCloudOnlyTests {
    @Test("an account on github.com searches per preset, one on GitHub Enterprise Server does not")
    func capabilities() {
        let provider = GitHubProvider()
        #expect(provider.capabilities(for: account([], baseURL: github)).presetSearch)
        #expect(!provider.capabilities(for: account([], baseURL: enterprise)).presetSearch)
        // Nothing else differs, and the kind alone promises no preset search.
        var cloud = provider.capabilities(for: account([], baseURL: github))
        cloud.presetSearch = false
        #expect(cloud == provider.capabilities)
        #expect(provider.capabilities(for: account([], baseURL: enterprise)) == provider.capabilities)
    }

    @Test("a GitHub Enterprise Server account is refused a preset search before anything is sent")
    func enterpriseIsRefused() async {
        let transport = ScriptedTransport { _ in SearchAnswer.empty }
        await #expect(throws: ProviderError.unsupported("Preset search")) {
            _ = try await GitHubProvider(transport: transport).fetchPresetItems(
                account: account([.organization(login: "acme")], baseURL: enterprise), token: "t", search: search([.pullRequest])
            )
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("GitHub Enterprise Server keeps the organization search of type ISSUE, 100 per page and three pages")
    func enterpriseKeepsTheOrganizationSearch() async throws {
        let transport = ScriptedTransport { request in
            let index = pageIndex(after: request.variables["after"])
            return SearchAnswer.page([SearchAnswer.node(.pullRequest, repo: "acme/app", number: index + 1)], issueCount: 900,
                                     endCursor: cursor(after: index), hasNextPage: true)
        }
        let items = try await GitHubProvider(transport: transport).fetchItems(
            account: account([.organization(login: "acme")], baseURL: enterprise), token: "t", kinds: [.pullRequest]
        )

        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.url?.absoluteString == "https://ghe.acme.test/api/graphql" })
        #expect(requests.allSatisfy { $0.query.contains("search(query: $q, type: ISSUE, first: 100, after: $after)") })
        #expect(requests.allSatisfy { $0.variables["q"] == "org:acme is:pr is:open archived:false sort:updated-desc" })
        #expect(items.map(\.number) == [1, 2, 3])
    }
}
