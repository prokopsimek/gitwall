import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

/// What an account shows when GitHub keeps answering its requests with 200 and a body that is not JSON. The client
/// repeats each such request twice, and what is left counts in the sync's quiet period like a gateway error: the first
/// and the second failed sync in a row leave the account as it was, the third shows the error.
@Suite("A sync over GitHub answers that are not JSON")
struct NotJSONSyncTests {
    private struct Tokens: TokenReading {
        func token(for accountID: UUID) async throws -> String? { "t" }
    }

    private let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub",
                                  me: UserRef(login: "octo-tester"), sources: [.repository(fullName: "octo-org/widgets")])
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// The answer for a repository source that has no open pull requests.
    private static let noPullRequests = StubTransport.Response.json(
        #"{"data":{"r0":{"nameWithOwner":"octo-org/widgets","pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#
    )

    /// A body cut off in the middle, as GitHub sent one after about 12 s.
    private static let cutOff = StubTransport.Response.json(#"{"data":{"r0":{"nameWith"#)

    @Test("the first and the second failed sync leave the account ok with its last success; the third shows the error")
    func quietPeriod() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitwall-not-json-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configStore = ConfigStore(directoryURL: directory)
        try configStore.save(AppConfig(accounts: [account], presets: [Preset(name: "Pull requests", kinds: [.pullRequest])]))
        let transport = StubTransport([Self.noPullRequests])
        let provider = GitHubProvider(transport: transport, sleep: { _ in })
        func sync(minutes: Double) async throws -> FetchStatus {
            let engine = SyncEngine(providers: [.github: provider], tokens: Tokens(), configStore: configStore,
                                    snapshotStore: SnapshotStore(directoryURL: directory),
                                    now: { [start] in start.addingTimeInterval(minutes * 60) })
            return try #require(try await engine.sync().snapshot.accountStatus[account.id])
        }

        let healthy = try await sync(minutes: 0)
        #expect(healthy.state == .ok)
        var failed: [FetchStatus] = []
        for series in 1...3 {
            // Every attempt of the request, the two repeats included, gets a body that is not JSON.
            await transport.enqueue([Self.cutOff, Self.cutOff, Self.cutOff])
            failed.append(try await sync(minutes: Double(series) * 5))
        }

        #expect(await transport.requests.count == 1 + 3 * 3)
        #expect(failed.map(\.consecutiveFailures) == [1, 2, 3])
        for quiet in failed.prefix(2) {
            #expect(quiet.state == .ok)
            #expect(quiet.message == nil)
            #expect(quiet.lastSuccessAt == start)
        }
        #expect(failed[2].state == .error)
        #expect(failed[2].message == "Network error: GitHub sent an answer that could not be read.")
        #expect(failed[2].lastSuccessAt == start)
    }
}
