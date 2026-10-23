import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!

@Suite("Project priorities")
struct ProjectPriorityTests {
    let account = Account(kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "prokopsimek"),
                          sources: [.organization(login: "acme")])

    private func item(_ number: Int, nodeID: String?) -> WorkItem {
        WorkItem(accountID: account.id, kind: .issue, repoFullName: "acme/app", number: number, title: "Item \(number)",
                 url: URL(string: "https://github.com/acme/app/issues/\(number)")!, author: UserRef(login: "jana"),
                 createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), nodeID: nodeID)
    }

    /// One node in the shape of the captured fixture, with one project item per `(closed, option)`.
    private func node(_ id: String, _ projects: [(closed: Bool, option: String?)]) -> String {
        let items = projects.map { project in
            let value = project.option.map { #"{"name":"\#($0)"}"# } ?? "null"
            return #"{"project":{"closed":\#(project.closed)},"fieldValueByName":\#(value)}"#
        }
        return #"{"id":"\#(id)","projectItems":{"nodes":[\#(items.joined(separator: ","))]}}"#
    }

    @Test("maps the captured answer: P1 and P2 found, a missing id and an unset field ignored")
    func mapsCapturedFixture() async throws {
        let transport = StubTransport([.json(try Fixtures.data("graphql_project_priorities.json"))])
        let items = [
            item(1, nodeID: "I_kwDOGitwallAAAAAP2issue"),
            item(2, nodeID: "I_kwDOGitwallAAAAAP1issue"),
            item(3, nodeID: "PR_kwDOGitwallAAAAAnone-A"),
            item(4, nodeID: "I_kwDOGitwallAAAAAnoneis"),
            item(5, nodeID: "I_kwDOAAAAAAAAAAAAAAAAAA"),
        ]

        let lookup = await GitHubProvider(transport: transport).projectPriorities(account: account, token: "t", items: items)

        #expect(lookup == .found([items[0].id: .p2, items[1].id: .p1]))
        let query = try await transport.graphQLQuery(at: 0)
        #expect(query.contains(#"nodes(ids: ["I_kwDOAAAAAAAAAAAAAAAAAA", "I_kwDOGitwallAAAAAP1issue""#))
        #expect(query.contains("projectItems(first: 10, includeArchived: false)"))
        #expect(query.contains(#"fieldValueByName(name: "Priority")"#))
        #expect(query.contains("... on PullRequest { id projectItems"))
    }

    @Test("the most urgent value across open projects wins; a closed project does not count")
    func mostUrgentOpenProject() async throws {
        let answer = #"{"data":{"nodes":[\#(node("I_a", [(false, "P2"), (false, "P1"), (true, "P0")])),\#(node("I_b", [(true, "P0")]))]}}"#
        let transport = StubTransport([.json(answer)])
        let items = [item(1, nodeID: "I_a"), item(2, nodeID: "I_b")]

        let lookup = await GitHubProvider(transport: transport).projectPriorities(account: account, token: "t", items: items)

        #expect(lookup == .found([items[0].id: .p1]))
    }

    @Test("options that are not P0 to P3 give no priority")
    func otherOptions() async throws {
        let answer = #"{"data":{"nodes":[\#(node("I_a", [(false, "High")])),\#(node("I_b", [(false, "P0 - urgent")]))]}}"#
        let transport = StubTransport([.json(answer)])
        let items = [item(1, nodeID: "I_a"), item(2, nodeID: "I_b")]

        let lookup = await GitHubProvider(transport: transport).projectPriorities(account: account, token: "t", items: items)

        #expect(lookup == .found([items[1].id: .p0]))
    }

    @Test("asks for at most 100 ids per request")
    func batches() async throws {
        let empty = #"{"data":{"nodes":[]}}"#
        let transport = StubTransport([.json(empty), .json(empty), .json(empty)])
        let items = (0..<201).map { item($0, nodeID: String(format: "I_%03d", $0)) }

        let lookup = await GitHubProvider(transport: transport).projectPriorities(account: account, token: "t", items: items)

        #expect(lookup == .found([:]))
        #expect(await transport.requests.count == 3)
        let first = try await transport.graphQLQuery(at: 0)
        #expect(first.contains(#""I_099"]"#))
        #expect(!first.contains(#""I_100""#))
    }

    @Test("a token without read:project is told apart from a failure, and nothing throws")
    func insufficientScopes() async throws {
        // GitHub's documented answer for a classic token that lacks the scope: errors only, no data.
        let refused = #"{"errors":[{"type":"INSUFFICIENT_SCOPES","locations":[{"line":3,"column":43}],"message":"Your token has not been granted the required scopes to execute this query. The 'projectItems' field requires one of the following scopes: ['read:project'], but your token has only been granted the: ['read:org', 'repo'] scopes."}]}"#
        let transport = StubTransport([.json(refused)])

        let lookup = await GitHubProvider(transport: transport).projectPriorities(account: account, token: "t", items: [item(1, nodeID: "I_a")])

        #expect(lookup == .missingPermission)
    }

    @Test("a field refused on its own, with nulls in the answer, is a missing permission too")
    func forbiddenPartialAnswer() async throws {
        let refused = #"{"data":{"nodes":[null]},"errors":[{"type":"FORBIDDEN","path":["nodes",0,"projectItems"],"message":"Resource not accessible by personal access token"}]}"#
        let transport = StubTransport([.json(refused)])

        let lookup = await GitHubProvider(transport: transport).projectPriorities(account: account, token: "t", items: [item(1, nodeID: "I_a")])

        #expect(lookup == .missingPermission)
    }

    @Test("an outage or the rate limit is a passing failure", arguments: [
        StubTransport.Response.json(#"{"message":"Bad gateway"}"#, status: 502),
        StubTransport.Response.json(#"{"message":"API rate limit exceeded"}"#, status: 403, headers: ["X-RateLimit-Remaining": "0"]),
        StubTransport.Response.json(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#),
    ])
    func passingFailure(response: StubTransport.Response) async throws {
        let transport = StubTransport([response])

        let lookup = await GitHubProvider(transport: transport).projectPriorities(account: account, token: "t", items: [item(1, nodeID: "I_a")])

        guard case .failed = lookup else {
            Issue.record("expected .failed, got \(lookup)")
            return
        }
    }

    @Test("items without a usable node id send nothing")
    func nothingToLookUp() async throws {
        let transport = StubTransport()

        let lookup = await GitHubProvider(transport: transport).projectPriorities(
            account: account, token: "t", items: [item(1, nodeID: nil), item(2, nodeID: #"I_"] } evil"#)]
        )

        guard case .failed = lookup else {
            Issue.record("expected .failed, got \(lookup)")
            return
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("the lists carry each item's node id for the lookup")
    func listsCarryNodeIDs() async throws {
        let page = """
        {"data":{"r0":{"nameWithOwner":"acme/app","isArchived":false,"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},\
        "nodes":[{"id":"I_kwDOAbc","number":1,"title":"Live","url":"https://github.com/acme/app/issues/1","createdAt":"2026-09-01T00:00:00Z",\
        "updatedAt":"2026-09-02T00:00:00Z","author":{"login":"jana"},"repository":{"nameWithOwner":"acme/app"}}]}}}}
        """
        let transport = StubTransport([.json(page)])
        let repoAccount = Account(kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "prokopsimek"),
                                  sources: [.repository(fullName: "acme/app")])

        let items = try await GitHubProvider(transport: transport).fetchItems(account: repoAccount, token: "t", kinds: [.issue])

        #expect(items.map(\.nodeID) == ["I_kwDOAbc"])
        #expect(try await transport.graphQLQuery(at: 0).contains("fragment Issue on Issue {\n  id number"))
    }
}
