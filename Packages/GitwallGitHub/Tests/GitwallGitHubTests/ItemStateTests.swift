import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!

@Suite("Item states")
struct ItemStateTests {
    let account = Account(kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "bob"),
                          sources: [.organization(login: "acme")])

    /// Only the team lookup has it; `viewer {` alone also matches `requestedReviewer {` in the pull request fragment.
    private static let teamLookup = "teams(first: 100, role: MEMBER)"
    private static let teams = #"{"data":{"viewer":{"organizations":{"nodes":[{"login":"acme","teams":{"nodes":[{"slug":"platform"}]}}]}}}}"#

    /// The copy of an item the snapshot held before it left a result: old title, nothing else that matters.
    private func stale(_ number: Int, _ kind: ItemKind, nodeID: String?) -> WorkItem {
        let path = kind == .pullRequest ? "pull" : "issues"
        return WorkItem(accountID: account.id, kind: kind, repoFullName: "acme/app", number: number, title: "Old title",
                        url: URL(string: "https://github.com/acme/app/\(path)/\(number)")!, author: UserRef(login: "heidi"),
                        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), nodeID: nodeID)
    }

    /// The items the captured answer is for, one per node it holds.
    private var capturedItems: [WorkItem] {
        [
            stale(12, .pullRequest, nodeID: "PR_kwDOAcme0012"), stale(13, .pullRequest, nodeID: "PR_kwDOAcme0013"),
            stale(14, .pullRequest, nodeID: "PR_kwDOAcme0014"), stale(99, .pullRequest, nodeID: "PR_kwDOAcme0099"),
            stale(30, .issue, nodeID: "I_kwDOAcme0030"), stale(31, .issue, nodeID: "I_kwDOAcme0031"),
        ]
    }

    private func nodesTransport(_ answer: StubTransport.Response) -> RoutingTransport {
        RoutingTransport([("nodes(ids:", answer), (Self.teamLookup, .json(Self.teams))])
    }

    /// What the preset search makes of the same nodes, from its captured fixtures.
    private func searchHits() async throws -> [Int: WorkItem] {
        let transport = RoutingTransport([
            ("fragment PR on PullRequest", .json(try Fixtures.data("graphql_preset_search_prs.json"))),
            ("fragment Issue on Issue", .json(try Fixtures.data("graphql_preset_search_issues.json"))),
            (Self.teamLookup, .json(Self.teams)),
        ])
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account, token: "t",
            search: PresetSearch(filter: .any, repositories: nil, sort: .lastActivity, kinds: [.pullRequest, .issue])
        )
        return Dictionary(uniqueKeysWithValues: fetch.items.map { ($0.number, $0) })
    }

    @Test("each node's state comes from the fragment: open, closed and merged pull requests, open and closed issues, a null node")
    func statesFromTheCapturedShape() async throws {
        let transport = nodesTransport(.json(try Fixtures.data("graphql_item_states.json")))
        let items = capturedItems

        let states = try await GitHubProvider(transport: transport).fetchItemStates(account: account, token: "t", items: items)

        let hits = try await searchHits()
        let byNumber = Dictionary(uniqueKeysWithValues: items.map { ($0.number, $0.id) })
        #expect(states == [
            try #require(byNumber[12]): .open(try #require(hits[12])),
            try #require(byNumber[13]): .closed,
            try #require(byNumber[14]): .merged,
            try #require(byNumber[99]): .notFound,
            try #require(byNumber[30]): .open(try #require(hits[30])),
            try #require(byNumber[31]): .closed,
        ])
        let queries = await transport.queries.filter { $0.contains("nodes(ids:") }
        #expect(queries.count == 1)
        let query = try #require(queries.first)
        #expect(query.contains(#"nodes(ids: ["I_kwDOAcme0030", "I_kwDOAcme0031", "PR_kwDOAcme0012", "PR_kwDOAcme0013", "PR_kwDOAcme0014", "PR_kwDOAcme0099"])"#))
        #expect(query.contains("__typename ... on PullRequest { state ...PR } ... on Issue { state ...Issue }"))
        #expect(query.contains("fragment PR on PullRequest {"))
        #expect(query.contains("fragment Issue on Issue {"))
        #expect(!query.contains("search("))
    }

    @Test("an open item maps exactly like a search hit: fresh data, team review requests resolved to me, one team lookup")
    func openMapsLikeASearchHit() async throws {
        let transport = nodesTransport(.json(try Fixtures.data("graphql_item_states.json")))
        let pull = stale(12, .pullRequest, nodeID: "PR_kwDOAcme0012")

        let states = try await GitHubProvider(transport: transport).fetchItemStates(account: account, token: "t", items: capturedItems)

        guard case .open(let fresh)? = states[pull.id] else {
            Issue.record("expected an open item, got \(String(describing: states[pull.id]))")
            return
        }
        #expect(fresh == (try await searchHits())[12])
        #expect(fresh.id == pull.id)
        #expect(fresh.title == "Rotate signing keys")
        #expect(fresh.requestedReviewers.map(\.login) == ["bob", "carol"])
        #expect(fresh.ciState == .success)
        #expect(fresh.nodeID == "PR_kwDOAcme0012")
        let queries = await transport.queries
        #expect(queries.count == 2)
        #expect(queries.filter { $0.contains(Self.teamLookup) }.count == 1)
    }

    @Test("asks for at most 100 ids per request: 150 items take two nodes requests")
    func batchesOfHundred() async throws {
        // GitHub answers in the order of the ids asked for; here every one of them is a closed issue.
        let transport = ScriptedTransport { request in
            let nodes = Self.ids(in: request.query).map { id in
                #"{"__typename":"Issue","state":"CLOSED","id":"\#(id)","number":1,"title":"Closed","url":"https://github.com/acme/app/issues/1","createdAt":"2026-11-01T09:00:00Z","updatedAt":"2026-11-18T09:00:00Z","author":{"login":"alice"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"milestone":null,"comments":{"totalCount":0},"repository":{"nameWithOwner":"acme/app"}}"#
            }
            return .json(#"{"data":{"nodes":[\#(nodes.joined(separator: ","))]}}"#)
        }
        let items = (0..<150).map { stale($0, .issue, nodeID: String(format: "I_kwDOAcme%04d", $0)) }

        let states = try await GitHubProvider(transport: transport).fetchItemStates(account: account, token: "t", items: items)

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.query.contains("nodes(ids: [") && !$0.query.contains("search(") })
        #expect(requests.map { Self.ids(in: $0.query).count } == [100, 50])
        #expect(Set(requests.flatMap { Self.ids(in: $0.query) }) == Set(items.compactMap(\.nodeID)))
        #expect(states == Dictionary(uniqueKeysWithValues: items.map { ($0.id, ItemState.closed) }))
    }

    @Test("items without a usable node id send nothing and get no state")
    func nothingToAsk() async throws {
        let transport = ScriptedTransport { _ in .json(#"{"data":{"nodes":[]}}"#) }

        let states = try await GitHubProvider(transport: transport).fetchItemStates(
            account: account, token: "t",
            items: [stale(1, .issue, nodeID: nil), stale(2, .issue, nodeID: #"I_"] } evil"#)]
        )

        #expect(states.isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test("a null node that an error other than NOT_FOUND points at, and a node of another type, get no state")
    func unknownAnswers() async throws {
        let answer = #"{"data":{"nodes":[null,{"__typename":"Discussion"}]},"errors":[{"type":"FORBIDDEN","path":["nodes",0],"message":"Resource protected by organization SAML enforcement."}]}"#
        let transport = nodesTransport(.json(answer))
        let items = [stale(1, .issue, nodeID: "I_kwDOAcme0001"), stale(2, .issue, nodeID: "I_kwDOAcme0002")]

        let states = try await GitHubProvider(transport: transport).fetchItemStates(account: account, token: "t", items: items)

        #expect(states.isEmpty)
    }

    @Test("a null node gets .notFound only when NOT_FOUND points at it, or no error does", arguments: [
        (#"[{"type":"NOT_FOUND","path":["nodes",0],"message":"Could not resolve to a node."}]"#, true),
        (#"[]"#, true),
        (#"[{"type":"FORBIDDEN","path":["nodes",0],"message":"saml"}]"#, false),
        (#"[{"type":"INTERNAL","path":["nodes",0],"message":"boom"}]"#, false),
        (#"[{"message":"boom","path":["nodes",0]}]"#, false),
    ])
    func nullNode(errors: String, notFound: Bool) async throws {
        let transport = nodesTransport(.json(#"{"data":{"nodes":[null]},"errors":\#(errors)}"#))
        let item = stale(1, .issue, nodeID: "I_kwDOAcme0001")

        let states = try await GitHubProvider(transport: transport).fetchItemStates(account: account, token: "t", items: [item])

        #expect(states == (notFound ? [item.id: .notFound] : [:]))
    }

    @Test("a lookup GitHub refuses throws, as every query does", arguments: [
        (StubTransport.Response.json(#"{"message":"Bad credentials"}"#, status: 401), ProviderError.unauthorized),
        (.json(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#), .rateLimited(resetAt: nil)),
    ])
    func failureThrows(answer: StubTransport.Response, expected: ProviderError) async {
        let provider = GitHubProvider(transport: StubTransport([answer]))
        await #expect(throws: expected) {
            _ = try await provider.fetchItemStates(account: account, token: "t", items: [stale(1, .issue, nodeID: "I_kwDOAcme0001")])
        }
    }

    /// The node ids a `nodes(ids:)` query asks for, in order.
    private static func ids(in query: String) -> [String] {
        guard let open = query.range(of: "nodes(ids: ["), let close = query.range(of: "])", range: open.upperBound..<query.endIndex) else {
            return []
        }
        return query[open.upperBound..<close.lowerBound].split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
    }
}
