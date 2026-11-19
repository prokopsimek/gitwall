import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!

@Suite("Item states")
struct ItemStateTests {
    let account = Account(kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "bob"),
                          sources: [.organization(login: Captured.owner)])

    /// Only the team lookup has it; `viewer {` alone also matches `requestedReviewer {` in the pull request fragment.
    private static let teamLookup = "teams(first: 100, role: MEMBER)"
    private static let teams = #"{"data":{"viewer":{"organizations":{"nodes":[{"login":"\#(Captured.owner)","teams":{"nodes":[{"slug":"platform"}]}}]}}}}"#
    private static var teamRequests: Captured.Object { Captured.teamReviewRequests(team: "platform", user: "carol") }

    /// The copy of an item the snapshot held before it left a result: old title, nothing else that matters.
    private func stale(_ number: Int, _ kind: ItemKind, nodeID: String?) -> WorkItem {
        let path = kind == .pullRequest ? "pull" : "issues"
        return WorkItem(accountID: account.id, kind: kind, repoFullName: Captured.repository, number: number, title: "Old title",
                        url: URL(string: "https://github.com/\(Captured.repository)/\(path)/\(number)")!, author: UserRef(login: "heidi"),
                        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), nodeID: nodeID)
    }

    /// The items the captured answer is for, one per node it holds, in its order: two closed issues, the id that names
    /// nothing, two merged pull requests.
    private func capturedItems() throws -> [WorkItem] {
        try Captured.stateNodes().map { node in
            guard let node = node as? Captured.Object, let number = node["number"] as? Int, let id = node["id"] as? String,
                  let typename = node["__typename"] as? String else {
                return stale(9, .issue, nodeID: Captured.missingNodeID)
            }
            return stale(number, typename == "PullRequest" ? .pullRequest : .issue, nodeID: id)
        }
    }

    private func nodesTransport(_ answer: StubTransport.Response) -> RoutingTransport {
        RoutingTransport([("nodes(ids:", answer), (Self.teamLookup, .json(Self.teams))])
    }

    /// The captured item-state answer with some of its nodes open, which the account has no item of in the
    /// public repository: only `state` changes, and the requests of a team and a user for the pull request that has them.
    private func answer(open numbers: Set<Int>, reviewRequests: Captured.Object? = nil) throws -> StubTransport.Response {
        let nodes: [Any] = try Captured.stateNodes().map { node in
            guard let node = node as? Captured.Object, let number = node["number"] as? Int, numbers.contains(number) else { return node }
            var changes: Captured.Object = ["state": "OPEN"]
            if node["__typename"] as? String == "PullRequest", let reviewRequests { changes["reviewRequests"] = reviewRequests }
            return Captured.with(node, changes)
        }
        return .json(try Captured.stateAnswer(nodes: nodes))
    }

    /// What the preset search makes of the same nodes, from the captured fixtures; the pull requests may carry the
    /// requests of a team and a user, as in ``answer(open:reviewRequests:)``.
    private func searchHits(reviewRequests: Captured.Object? = nil) async throws -> [Int: WorkItem] {
        let prs = try Captured.searchNodes("graphql_preset_search_prs.json").map { node in
            reviewRequests.map { Captured.with(node, ["reviewRequests": $0]) } ?? node
        }
        let transport = RoutingTransport([
            ("fragment PR on PullRequest", .json(try Captured.searchAnswer("graphql_preset_search_prs.json", nodes: prs))),
            ("fragment Issue on Issue", .json(try Fixtures.data("graphql_preset_search_issues.json"))),
            (Self.teamLookup, .json(Self.teams)),
        ])
        let fetch = try await GitHubProvider(transport: transport).fetchPresetItems(
            account: account, token: "t",
            search: PresetSearch(filter: .any, repositories: nil, sort: .lastActivity, kinds: [.pullRequest, .issue])
        )
        return Dictionary(uniqueKeysWithValues: fetch.items.map { ($0.number, $0) })
    }

    @Test("the captured answer: closed issues, merged pull requests, and the null node GitHub answers with NOT_FOUND at its place")
    func statesFromTheCapturedShape() async throws {
        let transport = nodesTransport(.json(try Fixtures.data("graphql_item_states.json")))
        let items = try capturedItems()

        let states = try await GitHubProvider(transport: transport).fetchItemStates(account: account, token: "t", items: items)

        #expect(states == [
            items[0].id: .closed,
            items[1].id: .closed,
            items[2].id: .notFound,
            items[3].id: .merged,
            items[4].id: .merged,
        ])
        let queries = await transport.queries.filter { $0.contains("nodes(ids:") }
        #expect(queries.count == 1)
        let query = try #require(queries.first)
        // The code asks in sorted order, and the answer was captured in that order.
        let ids = items.compactMap(\.nodeID).sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(items.compactMap(\.nodeID) == items.compactMap(\.nodeID).sorted())
        #expect(query.contains("nodes(ids: [\(ids)])"))
        #expect(query.contains("__typename ... on PullRequest { state ...PR } ... on Issue { state ...Issue }"))
        #expect(query.contains("fragment PR on PullRequest {"))
        #expect(query.contains("fragment Issue on Issue {"))
        #expect(!query.contains("search("))
    }

    @Test("the captured answer: the error names the null node by its path and the type NOT_FOUND")
    func capturedErrorShape() throws {
        let root = try Captured.object("graphql_item_states.json")
        let errors = try #require(root["errors"] as? [Captured.Object])
        let error = try #require(errors.first)
        let nodes = try Captured.stateNodes()
        let index = try #require(nodes.firstIndex { $0 is NSNull })

        #expect(errors.count == 1)
        #expect(error["type"] as? String == "NOT_FOUND")
        #expect((error["path"] as? [Any])?.count == 2)
        #expect((error["path"] as? [Any])?.first as? String == "nodes")
        #expect((error["path"] as? [Any])?.last as? Int == index)
        #expect((error["message"] as? String)?.contains(Captured.missingNodeID) == true)
    }

    @Test("derived from the captured answer with an issue and a pull request open: each maps like its search hit")
    func openNodesMapLikeSearchHits() async throws {
        let transport = nodesTransport(try answer(open: [1, 24]))
        let items = try capturedItems()

        let states = try await GitHubProvider(transport: transport).fetchItemStates(account: account, token: "t", items: items)

        let hits = try await searchHits()
        #expect(states == [
            items[0].id: .open(try #require(hits[1])),
            items[1].id: .closed,
            items[2].id: .notFound,
            items[3].id: .merged,
            items[4].id: .open(try #require(hits[24])),
        ])
    }

    @Test("derived with a pull request open that a team and a user asked: fresh data, the team request resolved to me, one team lookup")
    func openMapsLikeASearchHit() async throws {
        let transport = nodesTransport(try answer(open: [24], reviewRequests: Self.teamRequests))
        let items = try capturedItems()
        let pull = items[4]

        let states = try await GitHubProvider(transport: transport).fetchItemStates(account: account, token: "t", items: items)

        guard case .open(let fresh)? = states[pull.id] else {
            Issue.record("expected an open item, got \(String(describing: states[pull.id]))")
            return
        }
        #expect(fresh == (try await searchHits(reviewRequests: Self.teamRequests))[24])
        #expect(fresh.id == pull.id)
        let captured = try #require(try Captured.searchNodes("graphql_preset_search_prs.json").first { $0["number"] as? Int == 24 })
        #expect(fresh.title == captured["title"] as? String)
        #expect(fresh.requestedReviewers.map(\.login) == ["bob", "carol"])
        #expect(fresh.ciState == .success)
        #expect(fresh.nodeID == pull.nodeID)
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
