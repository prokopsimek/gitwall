import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!

/// What the sync counts: every request the client hands to its transport, so a repeat, a batch and a request that ends
/// in an error are all in it.
@Suite("Counting the requests of a provider")
struct RequestTallyTests {
    private let account = Account(kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "octo-tester"),
                                  sources: [.organization(login: "acme")])

    private func item(_ number: Int) -> WorkItem {
        WorkItem(accountID: account.id, kind: .issue, repoFullName: "acme/app", number: number, title: "Item \(number)",
                 url: URL(string: "https://github.com/acme/app/issues/\(number)")!, author: UserRef(login: "jana"),
                 createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                 nodeID: String(format: "I_%03d", number))
    }

    @Test("a repeat after a gateway error counts as a request of its own")
    func repeatsCount() async throws {
        let user = StubTransport.Response.json(try Fixtures.data("rest_user.json"))
        let transport = StubTransport([StubTransport.Response(status: 502), user])
        let waits = SleepRecorder()

        let (_, requests) = try await RequestTally.counting {
            try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")
        }

        #expect(requests == 2)
    }

    @Test("the project priority lookup counts one request per batch of 100")
    func priorityBatchesCount() async {
        let empty = StubTransport.Response.json(#"{"data":{"nodes":[]}}"#)
        let transport = StubTransport([empty, empty, empty])

        let (_, requests) = await RequestTally.counting {
            await GitHubProvider(transport: transport).projectPriorities(
                account: account, token: "t", items: (0..<201).map(item)
            )
        }

        #expect(requests == 3)
    }

    @Test("a preset fetch that fails counts all its attempts for whoever is counting around it, and its own count is the same")
    func failedFetchCounts() async throws {
        let gatewayError = StubTransport.Response(status: 502)
        let transport = StubTransport([gatewayError, gatewayError, gatewayError])
        let provider = GitHubProvider(transport: transport, sleep: { _ in })
        let search = PresetSearch(filter: .any, repositories: nil, sort: .lastActivity, kinds: [.issue])

        let (outcome, requests) = await RequestTally.counting { () async -> Result<PresetFetch, any Error> in
            do {
                return .success(try await provider.fetchPresetItems(account: account, token: "t", search: search))
            } catch {
                return .failure(error)
            }
        }

        #expect(requests == 3)
        #expect((try? outcome.get()) == nil)
        #expect(await transport.requests.count == 3)
    }

    @Test("a successful preset fetch counts in the sync's tally as many requests as it reports")
    func fetchCountsOnce() async throws {
        let empty = StubTransport.Response.json(
            #"{"data":{"rateLimit":{"cost":1,"remaining":4990,"resetAt":"2026-11-19T13:00:00Z"},"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#
        )
        let provider = GitHubProvider(transport: StubTransport([empty]))
        let search = PresetSearch(filter: .any, repositories: nil, sort: .lastActivity, kinds: [.issue])

        let (fetch, requests) = try await RequestTally.counting {
            try await provider.fetchPresetItems(account: account, token: "t", search: search)
        }

        #expect(fetch.requests == 1)
        #expect(requests == 1)
    }
}
