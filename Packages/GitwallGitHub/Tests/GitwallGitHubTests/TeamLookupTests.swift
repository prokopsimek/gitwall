import Foundation
import GitwallCore
import OSLog
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!

/// A clock a test moves by hand, so the lifetime of a cached lookup needs no sleeping.
private final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Answers the preset search, the item-state lookup and the team lookup from the captured fixtures, with the requests
/// of a team and a user added to pull request 24 (derived, see ``Captured``), and counts the team lookups. `teamAnswers` is what the lookup says each time it is asked; the last answer repeats.
private struct Fixture {
    static let teams = #"{"data":{"viewer":{"organizations":{"nodes":[{"login":"\#(Captured.owner)","teams":{"nodes":[{"slug":"platform"}]}}]}}}}"#
    static let teamLookup = "teams(first: 100, role: MEMBER)"

    let transport: ScriptedTransport
    let clock = TestClock()

    init(teamAnswers: [String] = [Fixture.teams]) throws {
        let requests = Captured.teamReviewRequests(team: "platform", user: "carol")
        let prNodes = try Captured.searchNodes("graphql_preset_search_prs.json").map { node in
            node["number"] as? Int == 24 ? Captured.with(node, ["reviewRequests": requests]) : node
        }
        let prs = try Captured.searchAnswer("graphql_preset_search_prs.json", nodes: prNodes)
        let issues = try Fixtures.data("graphql_preset_search_issues.json")
        let stateNodes: [Any] = try Captured.stateNodes().map { node in
            guard let node = node as? Captured.Object, node["number"] as? Int == 24 else { return node }
            return Captured.with(node, ["state": "OPEN", "reviewRequests": requests])
        }
        let states = try Captured.stateAnswer(nodes: stateNodes)
        let asked = OSAllocatedUnfairLock(initialState: 0)
        transport = ScriptedTransport { request in
            if request.query.contains(Self.teamLookup) {
                let index = asked.withLock { count -> Int in defer { count += 1 }; return count }
                return .json(teamAnswers[min(index, teamAnswers.count - 1)])
            }
            if request.query.contains("nodes(ids:") { return .json(states) }
            return request.query.contains("fragment PR on PullRequest") ? .json(prs) : .json(issues)
        }
    }

    func provider() -> GitHubProvider {
        let clock = clock
        return GitHubProvider(transport: transport, sleep: { _ in }, now: { clock.now })
    }

    var teamLookups: Int {
        get async { await transport.requests.filter { $0.query.contains(Self.teamLookup) }.count }
    }
}

private func account(_ id: UUID = UUID()) -> Account {
    Account(id: id, kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "bob"),
            sources: [.organization(login: Captured.owner)])
}

private let pullRequests = PresetSearch(filter: .any, repositories: nil, sort: .lastActivity, kinds: [.pullRequest])

/// The items the captured item-state answer is for, one per node it holds, in its order.
private func askedItems(for account: Account) throws -> [WorkItem] {
    try Captured.stateNodes().map { node in
        let object = node as? Captured.Object
        let number = object?["number"] as? Int ?? 9
        let isPull = object?["__typename"] as? String == "PullRequest"
        return WorkItem(accountID: account.id, kind: isPull ? .pullRequest : .issue, repoFullName: Captured.repository, number: number,
                        title: "Old title", url: URL(string: "https://github.com/\(Captured.repository)/pull/\(number)")!,
                        author: UserRef(login: "heidi"), createdAt: Date(timeIntervalSince1970: 0),
                        updatedAt: Date(timeIntervalSince1970: 0), nodeID: object?["id"] as? String ?? Captured.missingNodeID)
    }
}

@Suite("Team lookup: shared by one provider")
struct TeamLookupCacheTests {
    @Test("two preset searches of one account look at the viewer's teams once")
    func presetSearchesShareTheLookup() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let acme = account()

        let first = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)
        let second = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)

        #expect(await fixture.teamLookups == 1)
        // Both resolve the team request to me.
        for fetch in [first, second] {
            #expect(try #require(fetch.items.first { $0.number == 24 }).requestedReviewers.map(\.login) == ["bob", "carol"])
        }
    }

    @Test("an item-state lookup after the searches adds no team lookup")
    func itemStatesShareTheLookup() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let acme = account()
        _ = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)

        let items = try askedItems(for: acme)
        let pull = try #require(items.first { $0.number == 24 })
        let states = try await provider.fetchItemStates(account: acme, token: "t", items: items)

        guard case .open(let item)? = states[pull.id] else {
            Issue.record("Pull request 24 should come back open")
            return
        }
        #expect(item.requestedReviewers.map(\.login) == ["bob", "carol"])
        #expect(await fixture.teamLookups == 1)
    }

    @Test("a cached lookup adds no request to the count of a fetch")
    func cachedLookupIsNotCounted() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let acme = account()

        let first = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)
        let second = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)

        #expect(first.requests == 2)
        #expect(second.requests == 1)
    }

    @Test("another token, and another account, each look for themselves")
    func keyedByAccountAndToken() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let acme = account()

        _ = try await provider.fetchPresetItems(account: acme, token: "one", search: pullRequests)
        _ = try await provider.fetchPresetItems(account: acme, token: "two", search: pullRequests)
        #expect(await fixture.teamLookups == 2)

        _ = try await provider.fetchPresetItems(account: account(), token: "one", search: pullRequests)
        #expect(await fixture.teamLookups == 3)

        _ = try await provider.fetchPresetItems(account: acme, token: "one", search: pullRequests)
        #expect(await fixture.teamLookups == 3)
    }

    @Test("a lookup is repeated once five minutes have passed")
    func lookupExpires() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let acme = account()

        _ = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)
        fixture.clock.advance(by: 299)
        _ = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)
        #expect(await fixture.teamLookups == 1)

        fixture.clock.advance(by: 2)
        _ = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)
        #expect(await fixture.teamLookups == 2)
    }

    @Test("a refused lookup is not remembered: the next fetch asks again and resolves the team")
    func failureIsNotCached() async throws {
        let refused = #"{"data":null,"errors":[{"type":"FORBIDDEN","message":"Resource not accessible"}]}"#
        let fixture = try Fixture(teamAnswers: [refused, Fixture.teams])
        let provider = fixture.provider()
        let acme = account()

        let first = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)
        #expect(try #require(first.items.first { $0.number == 24 }).requestedReviewers.map(\.login) != ["bob", "carol"])

        let second = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)
        #expect(await fixture.teamLookups == 2)
        #expect(try #require(second.items.first { $0.number == 24 }).requestedReviewers.map(\.login) == ["bob", "carol"])
    }

    @Test("errors beside the teams are not remembered either")
    func partialAnswerIsNotCached() async throws {
        let partial = #"{"data":{"viewer":{"organizations":{"nodes":[{"login":"acme","teams":{"nodes":[{"slug":"platform"}]}}]}}},"errors":[{"type":"FORBIDDEN","message":"Resource not accessible"}]}"#
        let fixture = try Fixture(teamAnswers: [partial])
        let provider = fixture.provider()
        let acme = account()

        _ = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)
        _ = try await provider.fetchPresetItems(account: acme, token: "t", search: pullRequests)

        #expect(await fixture.teamLookups == 2)
    }

    @Test("within one fetch the lookup still happens at most once, failed or not")
    func oneLookupPerFetch() async throws {
        let refused = #"{"data":null,"errors":[{"type":"FORBIDDEN","message":"Resource not accessible"}]}"#
        let fixture = try Fixture(teamAnswers: [refused])
        let both = PresetSearch(filter: .any, repositories: nil, sort: .lastActivity, kinds: [.pullRequest, .issue])

        _ = try await fixture.provider().fetchPresetItems(account: account(), token: "t", search: both)

        #expect(await fixture.teamLookups == 1)
    }
}

@Suite("Team lookup: what is logged")
struct TeamLookupLogTests {
    private func errors(_ json: String) throws -> [GraphQLError] {
        try JSONDecoder().decode([GraphQLError].self, from: Data(json.utf8))
    }

    @Test("errors beside the teams are logged by count and type, never by their text")
    func errorsByCountAndType() throws {
        let line = TeamLookupLog.unresolved(try errors(
            #"[{"type":"FORBIDDEN","message":"The 'secret-org' organization forbids access via a personal access token"},{"type":"FORBIDDEN","message":"again secret-org"}]"#
        ))

        #expect(line.contains("2"))
        #expect(line.contains("FORBIDDEN"))
        #expect(!line.contains("secret-org"))
    }

    @Test("a thrown error is logged by its type, never by its description")
    func thrownByType() {
        let line = TeamLookupLog.failed(ProviderError.server(status: 403, message: "secret-org refuses this token"))

        #expect(line.contains("ProviderError"))
        #expect(!line.contains("secret-org"))
        #expect(!line.contains("403"))
    }
}
