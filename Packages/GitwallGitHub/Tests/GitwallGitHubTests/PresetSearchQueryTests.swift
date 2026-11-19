import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

/// One row of the translation: a preset filter, the kind it is searched for, and the top-level terms GitHub gets.
struct TranslationCase: Sendable, CustomTestStringConvertible {
    let name: String
    var kind: ItemKind = .pullRequest
    let filter: ItemFilter
    let expected: [String]

    var testDescription: String { name }

    static func query(_ name: String, _ query: String, kind: ItemKind = .pullRequest, _ expected: [String]) -> TranslationCase {
        TranslationCase(name: name, kind: kind, filter: ItemFilter(query: query), expected: expected)
    }
}

private let utc = TimeZone(identifier: "UTC")!

private func parseInstant(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = utc
    return formatter.date(from: text)
}

private func instant(_ text: String) -> Date { parseInstant(text)! }

/// A fixed `now` for every case that does not test the date itself.
private let now = instant("2026-11-19T12:00:00Z")

/// Gitwall sends a preset's filter to GitHub's search so that only roughly the right items are downloaded; the
/// local filter still decides what is shown. The search may therefore match more than the preset, never less.
@Suite("Preset search query")
struct PresetSearchQueryTests {
    // MARK: - Fields of the preset

    static let fields: [TranslationCase] = [
        TranslationCase(name: "no filter sends no terms", filter: ItemFilter(), expected: []),
        TranslationCase(name: "authored by me", filter: ItemFilter(relations: [.authoredByMe]), expected: ["author:@me"]),
        TranslationCase(name: "review requested from me", filter: ItemFilter(relations: [.reviewRequestedFromMe]),
                        expected: ["review-requested:@me"]),
        TranslationCase(name: "assigned to me", filter: ItemFilter(relations: [.assignedToMe]), expected: ["assignee:@me"]),
        TranslationCase(name: "several relations are one OR group",
                        filter: ItemFilter(relations: [.assignedToMe, .authoredByMe, .reviewRequestedFromMe]),
                        expected: ["(author:@me OR review-requested:@me OR assignee:@me)"]),
        // GitHub answers an issue search for review-requested:@me with nothing, and locally no issue has requested
        // reviewers either, so the group stays as it is.
        TranslationCase(name: "relations of an issue preset", kind: .issue,
                        filter: ItemFilter(relations: [.assignedToMe, .reviewRequestedFromMe]),
                        expected: ["(review-requested:@me OR assignee:@me)"]),
        TranslationCase(name: "authors any of, with the app form of each", filter: ItemFilter(authorsAny: ["alice"]),
                        expected: ["(author:alice OR author:app/alice)"]),
        TranslationCase(name: "authors any of drops a trailing [bot]", filter: ItemFilter(authorsAny: ["alice", "acme-bot[bot]"]),
                        expected: ["(author:alice OR author:app/alice OR author:acme-bot OR author:app/acme-bot)"]),
        // GitHub answers nothing at all when a negated login is unknown to it, a typo or a deleted account, and there is
        // no telling from here which logins it knows. Excluded authors are therefore left to the local filter.
        TranslationCase(name: "authors none of stay local", filter: ItemFilter(authorsNone: ["acme-bot[bot]", "bob"]), expected: []),
        TranslationCase(name: "authors none of leave the other fields", filter: ItemFilter(labelsNone: ["wip"], authorsNone: ["bob"]),
                        expected: [#"-label:"wip""#]),
        // The fields compare logins as written: "@me" is nobody there, so it cannot become GitHub's @me.
        TranslationCase(name: "authors fields take @me literally", filter: ItemFilter(authorsAny: ["@me", "alice"], authorsNone: ["@me"]),
                        expected: []),
        TranslationCase(name: "labels any of", filter: ItemFilter(labelsAny: ["bug", "needs review"]),
                        expected: [#"(label:"bug" OR label:"needs review")"#]),
        TranslationCase(name: "a single label needs no group", filter: ItemFilter(labelsAny: ["bug"]), expected: [#"label:"bug""#]),
        TranslationCase(name: "labels none of, one term each", filter: ItemFilter(labelsNone: ["wip", "needs review"]),
                        expected: [#"-label:"wip""#, #"-label:"needs review""#]),
        // A double quote cannot be written inside a quoted value, so that label is left to the local filter.
        TranslationCase(name: "a label GitHub cannot quote", filter: ItemFilter(labelsAny: ["bug", #"say "hi""#], labelsNone: [#"x"y"#, "wip"]),
                        expected: [#"-label:"wip""#]),
        TranslationCase(name: "milestone", filter: ItemFilter(milestone: " Q4 2026 "), expected: [#"milestone:"Q4 2026""#]),
        TranslationCase(name: "a blank milestone is no filter", filter: ItemFilter(milestone: "  "), expected: []),
        TranslationCase(name: "fields keep the order of the filter",
                        filter: ItemFilter(relations: [.assignedToMe], labelsNone: ["wip"], authorsAny: ["alice"], milestone: "M1",
                                           query: "label:bug"),
                        expected: ["assignee:@me", #"-label:"wip""#, "(author:alice OR author:app/alice)", #"milestone:"M1""#, #"label:"bug""#]),
    ]

    @Test("preset fields", arguments: fields)
    func translatesFields(_ row: TranslationCase) {
        #expect(PresetSearchQuery.filterTerms(for: row.filter, kind: row.kind, now: now) == row.expected)
    }

    // MARK: - Fields that stay local

    static let untranslated: [TranslationCase] = [
        TranslationCase(name: "drafts off", filter: ItemFilter(includeDrafts: false), expected: []),
        TranslationCase(name: "drafts that request my review",
                        filter: ItemFilter(relations: [.reviewRequestedFromMe], includeDrafts: false, includeDraftsRequestingMyReview: true),
                        expected: ["review-requested:@me"]),
        TranslationCase(name: "review states", filter: ItemFilter(reviewStates: [.approved, .changesRequested]), expected: []),
        TranslationCase(name: "CI states", filter: ItemFilter(ciStates: [.failure]), expected: []),
        TranslationCase(name: "merge states", filter: ItemFilter(mergeStates: [.conflict]), expected: []),
        TranslationCase(name: "text", filter: ItemFilter(text: "login"), expected: []),
        TranslationCase.query("free text of the query", "crash", []),
        TranslationCase.query("priority", "priority:P0,P1", []),
    ]

    @Test("fields GitHub search cannot answer the same way stay local", arguments: untranslated)
    func leavesFieldsLocal(_ row: TranslationCase) {
        #expect(PresetSearchQuery.filterTerms(for: row.filter, kind: row.kind, now: now) == row.expected)
    }

    // MARK: - Qualifiers of the query

    static let qualifiers: [TranslationCase] = [
        .query("author", "author:alice", ["(author:alice OR author:app/alice)"]),
        .query("author @me stays @me", "author:@me", ["author:@me"]),
        .query("a leading @ is dropped as locally", "author:@alice", ["(author:alice OR author:app/alice)"]),
        .query("a trailing [bot] is dropped as locally", "author:acme-bot[bot]", ["(author:acme-bot OR author:app/acme-bot)"]),
        // GitHub finds a bot's review only as app/<slug>; GraphQL, and so the snapshot, gives the slug alone.
        .query("assignee", "assignee:alice", ["(assignee:alice OR assignee:app/alice)"]),
        .query("assignee @me", "assignee:@me", ["assignee:@me"]),
        .query("reviewed-by", "reviewed-by:alice", ["(reviewed-by:alice OR reviewed-by:app/alice)"]),
        .query("review-requested", "review-requested:alice", ["(review-requested:alice OR review-requested:app/alice)"]),
        // Locally involves also covers reviewers and requested reviewers; GitHub's involves covers neither, nor apps.
        .query("involves", "involves:alice", [
            "(involves:alice OR involves:app/alice OR reviewed-by:alice OR reviewed-by:app/alice OR review-requested:alice OR review-requested:app/alice)",
        ]),
        .query("involves @me", "involves:@me", ["(involves:@me OR reviewed-by:@me OR review-requested:@me)"]),
        .query("label", "label:bug", [#"label:"bug""#]),
        .query("label with a space", #"label:"needs review""#, [#"label:"needs review""#]),
        .query("label with parentheses", #"label:"area (ui)""#, [#"label:"area (ui)""#]),
        .query("milestone", #"milestone:"Q4 2026""#, [#"milestone:"Q4 2026""#]),
        .query("repo", "repo:acme/app", ["repo:acme/app"]),
        .query("org", "org:acme", ["org:acme"]),
        // A login no account can have is left out rather than sent.
        .query("a login with a space", #"author:"a b" label:bug"#, [#"label:"bug""#]),
        .query("a repository that is not owner/name", #"repo:"acme app" label:bug"#, [#"label:"bug""#]),
    ]

    @Test("query qualifiers", arguments: qualifiers)
    func translatesQualifiers(_ row: TranslationCase) {
        #expect(PresetSearchQuery.filterTerms(for: row.filter, kind: row.kind, now: now) == row.expected)
    }

    // MARK: - Kind and state in the query

    /// GitHub's `is:` and `type:` choose which kind and state of item it searches rather than filter: `is:issue is:draft`
    /// answers with draft pull requests and `-is:open` with closed items. Every search here is already one kind and
    /// open, so these terms are decided before sending, except `is:draft`, which GitHub filters within pull requests.
    static let states: [TranslationCase] = [
        .query("is:pr in a pull request search", "is:pr label:bug", [#"label:"bug""#]),
        .query("is:pull-request reads as is:pr", "is:pull-request label:bug", [#"label:"bug""#]),
        .query("type:pr reads as is:pr", "type:pr label:bug", [#"label:"bug""#]),
        .query("is:issue in an issue search", "is:issue label:bug", kind: .issue, [#"label:"bug""#]),
        .query("is:open always holds", "is:open label:bug", [#"label:"bug""#]),
        .query("is:draft in a pull request search", "is:draft", ["is:draft"]),
        .query("type:draft reads as is:draft", "type:draft", ["is:draft"]),
        .query("-is:draft in a pull request search", "-is:draft", ["-is:draft"]),
        .query("-is:draft in an issue search", "-is:draft label:bug", kind: .issue, [#"label:"bug""#]),
        .query("-is:issue in a pull request search", "-is:issue label:bug", [#"label:"bug""#]),
        // These match nothing locally, so any search is wide enough; none is sent.
        .query("is:issue in a pull request search", "is:issue label:bug", []),
        .query("is:draft in an issue search", "is:draft label:bug", kind: .issue, []),
        .query("-is:open", "-is:open label:bug", []),
        .query("an OR branch that cannot hold falls away", "is:issue OR label:bug", [#"label:"bug""#]),
        .query("an OR branch that always holds empties the group", "is:pr OR label:bug", []),
    ]

    @Test("kind and state in the query", arguments: states)
    func decidesKindAndState(_ row: TranslationCase) {
        #expect(PresetSearchQuery.filterTerms(for: row.filter, kind: row.kind, now: now) == row.expected)
    }

    // MARK: - Commas, negation and groups

    static let algebra: [TranslationCase] = [
        .query("a comma list is an OR group", "label:bug,wip", [#"(label:"bug" OR label:"wip")"#]),
        .query("a comma list of logins", "assignee:alice,@me", ["(assignee:alice OR assignee:app/alice OR assignee:@me)"]),
        .query("a comma list of repositories", "repo:acme/app,acme/web", ["(repo:acme/app OR repo:acme/web)"]),
        .query("AND keeps what it can translate", "label:bug crash priority:P1 AND author:alice",
               [#"label:"bug""#, "(author:alice OR author:app/alice)"]),
        .query("OR with something untranslatable drops whole", "label:bug OR crash", []),
        .query("a dropped OR group leaves the rest", "(label:bug OR priority:P0) assignee:alice", ["(assignee:alice OR assignee:app/alice)"]),
        .query("an AND inside an OR stays grouped", #"(label:bug OR (assignee:alice milestone:"Q4 2026")) -label:wip"#, [
            #"(label:"bug" OR ((assignee:alice OR assignee:app/alice) milestone:"Q4 2026"))"#, #"-label:"wip""#,
        ]),
        .query("an AND that loses all but one term inside an OR", "(label:bug OR (crash assignee:alice))",
               [#"(label:"bug" OR assignee:alice OR assignee:app/alice)"#]),
        .query("a dropped OR inside an AND inside an OR", "label:bug OR (assignee:alice (crash OR label:wip))",
               [#"(label:"bug" OR assignee:alice OR assignee:app/alice)"#]),
        .query("a dropped group deep inside drops its OR", "((crash OR priority:P0) OR label:bug) label:wip", [#"label:"wip""#]),
        .query("a group that is empty after dropping disappears", "(crash) label:bug", [#"label:"bug""#]),
        // A negated login goes out only as @me, which GitHub always knows; any other could empty the whole search.
        .query("-author of a login stays local", "-author:alice label:bug", [#"label:"bug""#]),
        .query("-author of an app stays local", "-author:acme-bot[bot] label:bug", [#"label:"bug""#]),
        .query("-author @me", "-author:@me", ["-author:@me"]),
        .query("-assignee of a login stays local", "-assignee:alice label:bug", [#"label:"bug""#]),
        .query("-assignee @me", "-assignee:@me", ["-assignee:@me"]),
        .query("a negated list keeps only @me", "-assignee:alice,@me", ["-assignee:@me"]),
        .query("-label of a list excludes each", "-label:bug,wip", [#"-label:"bug""#, #"-label:"wip""#]),
        .query("-milestone", #"-milestone:"Q4 2026""#, [#"-milestone:"Q4 2026""#]),
        .query("-repo and -org", "-repo:acme/app -org:acme", ["-repo:acme/app", "-org:acme"]),
        // GitHub's involves misses reviews, its review-requested includes teams and its reviewed-by sees more reviews
        // than the snapshot, so excluding them there could hide items the preset shows.
        .query("-involves drops", "-involves:alice label:bug", [#"label:"bug""#]),
        .query("-involves @me drops", "-involves:@me label:bug", [#"label:"bug""#]),
        .query("-reviewed-by drops", "-reviewed-by:alice label:bug", [#"label:"bug""#]),
        .query("-reviewed-by @me drops", "-reviewed-by:@me label:bug", [#"label:"bug""#]),
        .query("-review-requested drops", "-review-requested:alice label:bug", [#"label:"bug""#]),
        .query("-review-requested @me drops", "-review-requested:@me label:bug", [#"label:"bug""#]),
        .query("negated free text drops", "-crash label:bug", [#"label:"bug""#]),
        .query("a negated login in an OR group drops the group", "label:bug OR -author:alice", []),
        .query("a negated @me in an OR group", "label:bug OR -author:@me", [#"(label:"bug" OR -author:@me)"#]),
        // Locally an unreadable query matches nothing, so any search is wide enough for it.
        .query("an unreadable query drops whole", "label:bug mentions:alice", []),
        .query("an unclosed parenthesis drops whole", "(label:bug", []),
        TranslationCase(name: "an unreadable query keeps the other fields", filter: ItemFilter(labelsAny: ["bug"], query: "author:"),
                        expected: [#"label:"bug""#]),
        .query("an empty query", "   ", []),
    ]

    @Test("commas, negation and groups", arguments: algebra)
    func dropsWhatCannotBeSaid(_ row: TranslationCase) {
        #expect(PresetSearchQuery.filterTerms(for: row.filter, kind: row.kind, now: now) == row.expected)
    }

    // MARK: - Updated within

    @Test("updated within sends the day before the cutoff's UTC date", arguments: [
        ("2026-11-19T00:30:00Z", 7, "updated:>=2026-11-11"),
        ("2026-11-18T23:30:00Z", 1, "updated:>=2026-11-16"),
        ("2026-11-19T00:00:00Z", 1, "updated:>=2026-11-17"),
        ("2026-03-01T06:00:00Z", 1, "updated:>=2026-02-27"),
    ])
    func updatedWithin(now: String, days: Int, expected: String) {
        let filter = ItemFilter(updatedWithinDays: days)
        #expect(PresetSearchQuery.filterTerms(for: filter, kind: .issue, now: instant(now)) == [expected])
    }

    /// GitHub reads a bare date as the start of that day somewhere between UTC−12 and UTC+14. Even at UTC−12 that is
    /// 12:00 UTC of the day sent, which must not be later than the moment `FilterEngine` compares against.
    @Test("updated within is never later than the local cutoff, around every hour of two days")
    func updatedWithinNeverNarrower() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let start = instant("2026-12-31T00:00:00Z")
        for step in 0..<(48 * 4) {
            let moment = start.addingTimeInterval(Double(step) * 900)
            for days in [0, 1, 2, 7, 30] {
                let terms = PresetSearchQuery.filterTerms(for: ItemFilter(updatedWithinDays: days), kind: .pullRequest, now: moment)
                let term = try #require(terms.first)
                let day = try #require(parseInstant(String(term.dropFirst("updated:>=".count)) + "T00:00:00Z"))
                let cutoff = moment.addingTimeInterval(-Double(days) * 86_400)
                #expect(day.addingTimeInterval(12 * 3600) <= cutoff, "\(term) for \(days) days at \(moment)")
                #expect(day.addingTimeInterval(48 * 3600) > cutoff, "\(term) is more than two days early")
            }
        }
    }

    @Test("an updated-within reaching before GitHub existed, or into the future, sends no date")
    func updatedWithinOutOfRange() {
        #expect(PresetSearchQuery.filterTerms(for: ItemFilter(updatedWithinDays: 100_000), kind: .issue, now: now) == [])
        #expect(PresetSearchQuery.filterTerms(for: ItemFilter(updatedWithinDays: Int.max), kind: .issue, now: now) == [])
        // A cutoff in the future matches nothing locally, so any search is wide enough.
        #expect(PresetSearchQuery.filterTerms(for: ItemFilter(updatedWithinDays: -1), kind: .issue, now: now) == [])
    }

    // MARK: - The whole query

    @Test("each search carries kind, open, the sources as one group, archived:false and the sort")
    func wholeQuery() {
        let query = PresetSearchQuery.query(
            kind: .pullRequest,
            sources: ["org:acme", "repo:acme/app"],
            filterTerms: [#"label:"bug""#, "(author:bob OR author:app/bob)"],
            sort: .newestCreated
        )
        #expect(query == #"is:pr is:open (org:acme OR repo:acme/app) archived:false label:"bug" (author:bob OR author:app/bob) sort:created-desc"#)
    }

    @Test("a preset without a filter sends only kind, state, the source, archived:false and the sort")
    func presetWithoutFilter() {
        let terms = PresetSearchQuery.filterTerms(for: ItemFilter(), kind: .issue, now: now)
        let query = PresetSearchQuery.query(kind: .issue, sources: ["org:acme"], filterTerms: terms, sort: .lastActivity)
        #expect(query == "is:issue is:open org:acme archived:false sort:updated-desc")
    }

    @Test("every sort order maps to an order GitHub keeps stable while paging", arguments: [
        (GitwallCore.SortOrder.lastActivity, "sort:updated-desc"),
        (.newestCreated, "sort:created-desc"),
        (.oldestCreated, "sort:created-asc"),
        // GitHub cannot sort by priority; the local sort orders what comes back.
        (.priority, "sort:updated-desc"),
    ])
    func sortQualifier(order: GitwallCore.SortOrder, expected: String) {
        #expect(PresetSearchQuery.sortQualifier(for: order) == expected)
    }

    @Test("every sort order, including one added later, maps to one of GitHub's own sorts", arguments: GitwallCore.SortOrder.allCases)
    func everySortOrderIsGitHubs(order: GitwallCore.SortOrder) {
        #expect(["sort:updated-desc", "sort:created-desc", "sort:created-asc"].contains(PresetSearchQuery.sortQualifier(for: order)))
    }
}

// MARK: - Against GitHub

/// Checks the translation against GitHub itself. For every row, each item the local filter keeps out of the repository's
/// open items must also be in GitHub's answer to the translated query. The values come from the repository's own data,
/// so no login, label or milestone is written here; a row whose role has nobody in the data is reported as skipped, and
/// rows with `@me` are left to the real account. The summary prints counts only.
///
///     GITWALL_GITHUB_TOKEN=$(gh auth token) swift test --package-path Packages/GitwallGitHub --filter PresetSearchQueryLiveTests
///
/// `GITWALL_GITHUB_REPO` picks the repository, `cli/cli` by default. It takes a few minutes and reads public data only.
@Suite("Preset search query against GitHub", .enabled(if: ProcessInfo.processInfo.environment["GITWALL_GITHUB_TOKEN"] != nil))
struct PresetSearchQueryLiveTests {
    private let token = ProcessInfo.processInfo.environment["GITWALL_GITHUB_TOKEN"] ?? ""
    private let repo = ProcessInfo.processInfo.environment["GITWALL_GITHUB_REPO"].flatMap { $0.isEmpty ? nil : $0 } ?? "cli/cli"
    private let provider = GitHubProvider()
    private let endpoints = GitHubEndpoints(baseURL: URL(string: "https://github.com")!)

    @Test("what the local filter keeps is a subset of what GitHub answers, row by row")
    func localIsSubsetOfServer() async throws {
        let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub",
                              sources: [.repository(fullName: repo)])
        let now = Date()
        let items = try await provider.fetchItems(account: account, token: token, kinds: [.pullRequest, .issue])
        let data = RepositoryData(repo: repo, items: items, bots: try await botLogins())
        print("preset search live | \(repo) | \(data.pulls.count) pull requests, \(data.issues.count) issues")
        #expect(!data.pulls.isEmpty, "\(repo) has no open pull requests to check against")

        for row in data.rows {
            guard let filter = row.filter else {
                print("preset search live | \(row.name) | skipped: \(row.skipped)")
                continue
            }
            let local = FilterEngine.items(matching: Preset(name: row.name, kinds: [row.kind], filter: filter), in: items,
                                           accounts: [account], now: now)
            let query = PresetSearchQuery.query(kind: row.kind, sources: ["repo:\(repo)"],
                                                filterTerms: PresetSearchQuery.filterTerms(for: filter, kind: row.kind, now: now),
                                                sort: .lastActivity)
            let server = try await search(query, kind: row.kind, until: Set(local.map(\.url)))
            let absent = local.filter { !server.urls.contains($0.url) }
            let changed = try await changedSinceFetch(absent, now: now)
            let missing = absent.filter { !changed.contains($0.id) }

            var line = "preset search live | \(row.name) | local \(local.count) | server \(server.total) | subset \(missing.isEmpty ? "yes" : "no")"
            if !changed.isEmpty { line += " | \(changed.count) changed since the fetch" }
            if server.otherKind > 0 { line += " | \(server.otherKind) of the other kind" }
            print(line)
            #expect(missing.isEmpty, "\(row.name): GitHub's answer lacks \(missing.map(\.url.absoluteString))")
            #expect(server.otherKind == 0, "\(row.name): GitHub answered with the other kind of item")
        }
    }

    // MARK: Requests

    private struct SearchPage: Decodable {
        struct Hit: Decodable {
            let __typename: String?
            let url: URL?
        }
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
        struct Search: Decodable {
            let issueCount: Int
            let pageInfo: PageInfo?
            let nodes: [Hit?]
        }
        let search: Search
    }

    /// Pages through the preset search the way the sync will, until every item in `wanted` turned up, GitHub has no more
    /// pages or the 1000-result cap is reached. `total` is GitHub's own count of matches.
    private func search(_ query: String, kind: ItemKind, until wanted: Set<URL>) async throws -> (urls: Set<URL>, total: Int, otherKind: Int) {
        var urls: Set<URL> = []
        var total = 0
        var otherKind = 0
        var read = 0
        var after: String?
        while true {
            let response = try await provider.client.graphQL(SearchPage.self, endpoint: endpoints.graphQL, token: token,
                                                             query: GraphQLQueries.presetSearch(kind: kind),
                                                             variables: ["q": query, "after": after])
            guard let search = response.data?.search else { break }
            total = search.issueCount
            for hit in search.nodes.compactMap({ $0 }) {
                guard (hit.__typename == "PullRequest") == (kind == .pullRequest) else {
                    otherKind += 1
                    continue
                }
                if let url = hit.url { urls.insert(url) }
            }
            read += search.nodes.count
            guard !wanted.isSubset(of: urls), read < GraphQLQueries.maxPresetSearchResults,
                  let page = search.pageInfo, page.hasNextPage, let cursor = page.endCursor else { break }
            after = cursor
        }
        return (urls, total, otherKind)
    }

    private struct NodesPage: Decodable {
        struct Node: Decodable {
            let id: String?
            let state: String?
            let updatedAt: Date?
        }
        let nodes: [Node?]
    }

    /// Items GitHub's index cannot be expected to agree on yet: closed or changed since the fetch, or changed in the ten
    /// minutes before it. Anything else that is missing is a translation that came out too narrow.
    private func changedSinceFetch(_ items: [WorkItem], now: Date) async throws -> Set<String> {
        let byNode = Dictionary(items.compactMap { item in item.nodeID.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
        guard !byNode.isEmpty else { return [] }
        let ids = byNode.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        let query = "query { nodes(ids: [\(ids)]) { ... on PullRequest { id state updatedAt } ... on Issue { id state updatedAt } } }"
        let response = try await provider.client.graphQL(NodesPage.self, endpoint: endpoints.graphQL, token: token, query: query)
        var changed: Set<String> = []
        for node in response.data?.nodes.compactMap({ $0 }) ?? [] {
            guard let id = node.id, let item = byNode[id] else { continue }
            let updated = node.updatedAt ?? item.updatedAt
            if node.state != "OPEN" || updated > item.updatedAt || updated > now.addingTimeInterval(-600) {
                changed.insert(item.id)
            }
        }
        return changed
    }

    private struct BotPage: Decodable {
        struct Actor: Decodable {
            let __typename: String?
            let login: String?
        }
        struct Review: Decodable { let author: Actor? }
        struct Reviews: Decodable { let nodes: [Review?] }
        struct Node: Decodable {
            let author: Actor?
            let latestReviews: Reviews?
        }
        struct Search: Decodable { let nodes: [Node?] }
        let search: Search
    }

    /// The snapshot cannot tell a bot from a person, so ask GitHub who among the recent authors and reviewers is one.
    private func botLogins() async throws -> Set<String> {
        let document = """
        query($q: String!) { search(query: $q, type: ISSUE_ADVANCED, first: 100) { nodes {
          ... on PullRequest { author { __typename login } latestReviews(first: 20) { nodes { author { __typename login } } } }
          ... on Issue { author { __typename login } }
        } } }
        """
        var bots: Set<String> = []
        for kind in ["is:pr", "is:issue"] {
            let response = try await provider.client.graphQL(BotPage.self, endpoint: endpoints.graphQL, token: token, query: document,
                                                             variables: ["q": "repo:\(repo) \(kind) is:open sort:updated-desc"])
            for node in response.data?.search.nodes.compactMap({ $0 }) ?? [] {
                let actors = [node.author] + (node.latestReviews?.nodes.map { $0?.author } ?? [])
                for case let actor? in actors where actor.__typename == "Bot" {
                    if let login = actor.login { bots.insert(login.lowercased()) }
                }
            }
        }
        return bots
    }
}

/// The repository's open items and the real values the rows are built from.
private struct RepositoryData {
    struct Row {
        let name: String
        let kind: ItemKind
        let filter: ItemFilter?
        let skipped: String
    }

    let repo: String
    let pulls: [WorkItem]
    let issues: [WorkItem]
    let bots: Set<String>

    init(repo: String, items: [WorkItem], bots: Set<String>) {
        self.repo = repo
        pulls = items.filter { $0.kind == .pullRequest }
        issues = items.filter { $0.kind == .issue }
        self.bots = bots
    }

    private func isBot(_ login: String) -> Bool { bots.contains(login.lowercased()) }

    /// The most frequent value, ties broken by name, so a run is repeatable on the same data.
    private func mostCommon(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.lowercased() < rhs.key.lowercased()
        }.map(\.key)
    }

    private func people(_ logins: [String]) -> String? { mostCommon(logins.filter { !isBot($0) && $0 != "ghost" }).first }
    private func botsAmong(_ logins: [String]) -> String? { mostCommon(logins.filter(isBot)).first }
    /// Names that can be quoted in a query.
    private func names(_ values: [String]) -> [String] { mostCommon(values.filter { !$0.contains("\"") && !$0.contains(",") }) }

    var rows: [Row] {
        let author = people(pulls.map(\.author.login))
        let botAuthor = botsAmong(pulls.map(\.author.login))
        let reviewer = people(pulls.flatMap(\.reviewers).map(\.login))
        let botReviewer = botsAmong(pulls.flatMap(\.reviewers).map(\.login))
        let requested = people(pulls.flatMap(\.requestedReviewers).map(\.login))
        let labels = names(pulls.flatMap(\.labels).map(\.name))
        let label: String? = labels.first
        let otherLabel: String? = labels.dropFirst().first
        let issueLabel: String? = names(issues.flatMap(\.labels).map(\.name)).first
        let assignee: (login: String, kind: ItemKind)?
        if let login = people(pulls.flatMap(\.assignees).map(\.login)) {
            assignee = (login, .pullRequest)
        } else {
            assignee = people(issues.flatMap(\.assignees).map(\.login)).map { ($0, .issue) }
        }
        let milestone: (title: String, kind: ItemKind)?
        if let title = names(issues.compactMap(\.milestone)).first {
            milestone = (title, .issue)
        } else {
            milestone = names(pulls.compactMap(\.milestone)).first.map { ($0, .pullRequest) }
        }
        let owner = String(repo.split(separator: "/").first ?? "")

        var rows: [Row] = []
        func add(_ name: String, kind: ItemKind = .pullRequest, needs role: String = "", _ filter: ItemFilter?) {
            rows.append(Row(name: name, kind: kind, filter: filter, skipped: "no \(role) in the data"))
        }
        func addQuery(_ name: String, kind: ItemKind = .pullRequest, needs role: String = "", _ text: String?) {
            add(name, kind: kind, needs: role, text.map { ItemFilter(query: $0) })
        }
        func both(_ first: String?, _ second: String?) -> (String, String)? {
            guard let first, let second else { return nil }
            return (first, second)
        }

        add("kind and state only, pull requests", ItemFilter())
        add("kind and state only, issues", kind: .issue, ItemFilter())
        rows.append(Row(name: "relations and @me in the query", kind: .pullRequest, filter: nil, skipped: "@me needs the real account"))
        add("authorsAny, person", needs: "pull request author", author.map { ItemFilter(authorsAny: [$0]) })
        add("authorsAny, bot written with [bot]", needs: "bot author", botAuthor.map { ItemFilter(authorsAny: [$0 + "[bot]"]) })
        add("authorsNone, person", needs: "pull request author", author.map { ItemFilter(authorsNone: [$0]) })
        add("authorsNone, bot", needs: "bot author", botAuthor.map { ItemFilter(authorsNone: [$0]) })
        add("labelsAny, two labels", needs: "pull request label",
            label.map { ItemFilter(labelsAny: [$0] + (otherLabel.map { [$0] } ?? [])) })
        add("labelsNone", needs: "pull request label", label.map { ItemFilter(labelsNone: [$0]) })
        add("labelsAny, issues", kind: .issue, needs: "issue label", issueLabel.map { ItemFilter(labelsAny: [$0]) })
        add("updatedWithinDays 7, pull requests", ItemFilter(updatedWithinDays: 7))
        add("updatedWithinDays 2, issues", kind: .issue, ItemFilter(updatedWithinDays: 2))
        add("milestone", kind: milestone?.kind ?? .issue, needs: "milestone", milestone.map { ItemFilter(milestone: $0.title) })
        add("drafts, review, CI and merge states, text stay local",
            ItemFilter(includeDrafts: false, reviewStates: [.approved, .pending, .none], ciStates: [.success, .none],
                       mergeStates: [.clean, .unknown], text: "e"))

        addQuery("query author:, person", needs: "pull request author", author.map { "author:\($0)" })
        addQuery("query author:, bot as the snapshot names it", needs: "bot author", botAuthor.map { "author:\($0)" })
        addQuery("query assignee:", kind: assignee?.kind ?? .pullRequest, needs: "assignee", assignee.map { "assignee:\($0.login)" })
        addQuery("query -assignee:", kind: assignee?.kind ?? .pullRequest, needs: "assignee", assignee.map { "-assignee:\($0.login)" })
        addQuery("query label:, comma list", needs: "two pull request labels", both(label, otherLabel).map { "label:\"\($0.0),\($0.1)\"" })
        addQuery("query milestone:", kind: milestone?.kind ?? .issue, needs: "milestone", milestone.map { "milestone:\"\($0.title)\"" })
        addQuery("query reviewed-by:, person", needs: "reviewer", reviewer.map { "reviewed-by:\($0)" })
        addQuery("query reviewed-by:, bot", needs: "bot reviewer", botReviewer.map { "reviewed-by:\($0)" })
        addQuery("query review-requested:", needs: "requested reviewer", requested.map { "review-requested:\($0)" })
        addQuery("query involves:, person", needs: "reviewer", reviewer.map { "involves:\($0)" })
        addQuery("query involves:, bot reviewer", needs: "bot reviewer", botReviewer.map { "involves:\($0)" })
        addQuery("query repo: and org:", "repo:\(repo) org:\(owner)")
        addQuery("query is:draft", "is:draft")
        addQuery("query -is:draft", "-is:draft")
        addQuery("query is:pull-request", "is:pull-request")
        addQuery("query type:issue is:open", kind: .issue, "type:issue is:open")
        addQuery("query negated author and label", needs: "pull request author and label",
                 both(author, label).map { "-author:\($0.0) -label:\"\($0.1)\"" })
        addQuery("query OR", needs: "pull request author and label", both(author, label).map { "label:\"\($0.1)\" OR author:\($0.0)" })
        addQuery("query nested groups", needs: "pull request author and two labels",
                 both(author, label).flatMap { pair in otherLabel.map { "(label:\"\(pair.1)\" OR (author:\(pair.0) -label:\"\($0)\")) -is:draft" } })
        addQuery("query with terms that stay local", needs: "pull request author and label",
                 both(author, label).map { "e priority:P1 -involves:\($0.0) label:\"\($0.1)\"" })
        addQuery("query that cannot be read", "mentions:x")
        return rows
    }
}
