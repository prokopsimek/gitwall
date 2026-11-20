import Foundation
import Testing
@testable import GitwallCore

@Suite("Snapshot coding")
struct SnapshotCodingTests {
    @Test("decodes the fixture written by the app")
    func decodesFixture() throws {
        let data = try Fixtures.data("snapshot.json")
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: data)

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.items.count == 2)

        let pr = try #require(snapshot.items.first { $0.kind == .pullRequest })
        #expect(pr.repoFullName == "dxheroes/mcp-gateway")
        #expect(pr.number == 42)
        #expect(pr.title == "Add GitLab provider")
        #expect(pr.url.absoluteString == "https://github.com/dxheroes/mcp-gateway/pull/42")
        #expect(pr.author.login == "prokopsimek")
        #expect(pr.isDraft == false)
        #expect(pr.reviewState == .approved)
        #expect(pr.ciState == .success)
        #expect(pr.mergeState == .clean)
        #expect(pr.additions == 120)
        #expect(pr.deletions == 7)
        #expect(pr.labels.map(\.name) == ["provider", "gitlab"])
        #expect(pr.requestedReviewers.map(\.login) == ["alice"])

        let issue = try #require(snapshot.items.first { $0.kind == .issue })
        #expect(issue.number == 7)
        #expect(issue.reviewState == nil)
        #expect(issue.ciState == nil)
        #expect(issue.mergeState == nil)
        #expect(issue.assignees.map(\.login) == ["bob"])
        #expect(issue.milestone == "v0.1")
    }

    @Test("dates are ISO 8601 with fractional seconds")
    func datesAreISO8601() throws {
        let data = try Fixtures.data("snapshot.json")
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: data)
        let pr = try #require(snapshot.items.first { $0.kind == .pullRequest })

        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-10T06:30:00Z"))
        #expect(pr.updatedAt == expected)
    }

    @Test("encode then decode yields an equal snapshot")
    func roundTrip() throws {
        let original = try SnapshotCoding.decode(Snapshot.self, from: Fixtures.data("snapshot.json"))
        let encoded = try SnapshotCoding.encode(original)
        let decoded = try SnapshotCoding.decode(Snapshot.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("an account status written before the failure count existed reads as no failures in a row")
    func statusWithoutFailureCount() throws {
        let json = """
        {
          "schemaVersion": 1,
          "fetchedAt": "2026-09-10T06:35:00.000Z",
          "items": [],
          "accountStatus": {
            "8A2F7C1E-1111-2222-3333-444455556666": {
              "state": "error",
              "lastSuccessAt": "2026-09-10T06:00:00.000Z",
              "message": "Server error 503: Service Unavailable",
              "projectAccess": "granted"
            }
          }
        }
        """
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: Data(json.utf8))

        let account = try #require(UUID(uuidString: "8A2F7C1E-1111-2222-3333-444455556666"))
        let status = try #require(snapshot.accountStatus[account])
        #expect(status.consecutiveFailures == 0)
        #expect(status.state == .error)
        #expect(status.message == "Server error 503: Service Unavailable")
        #expect(status.projectAccess == .granted)
    }

    @Test("the failure count is written and read back")
    func failureCountRoundTrips() throws {
        let account = UUID()
        let snapshot = Snapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), items: [],
            accountStatus: [account: FetchStatus(state: .ok, lastSuccessAt: Date(timeIntervalSince1970: 1_799_999_400),
                                                 consecutiveFailures: 2)]
        )
        let encoded = try SnapshotCoding.encode(snapshot)

        #expect(String(decoding: encoded, as: UTF8.self).contains(#""consecutiveFailures" : 2"#))
        let decoded = try SnapshotCoding.decode(Snapshot.self, from: encoded)
        #expect(decoded == snapshot)
        #expect(decoded.accountStatus[account]?.consecutiveFailures == 2)
    }

    // MARK: - Preset results

    static let presetA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let presetB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let accountA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let accountB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    @Test("a snapshot written before preset results existed loads with none")
    func versionOneWithoutResults() throws {
        let json = """
        {
          "schemaVersion": 1,
          "fetchedAt": "2026-09-10T06:35:00.000Z",
          "items": [],
          "accountStatus": {}
        }
        """
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: Data(json.utf8))

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.presetResults.isEmpty)
    }

    @Test("preset results are written under schema version 2 and read back unchanged")
    func resultsRoundTrip() throws {
        let fetched = PresetResult(
            presetID: Self.presetA, accountID: Self.accountA,
            itemIDs: ["\(Self.accountA.uuidString)/acme/app#1/pullRequest", "\(Self.accountA.uuidString)/acme/app#2/issue"],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), totalCount: 1_200, isComplete: false,
            selection: "selection-a",
            failure: PresetQueryFailure(code: "validation", at: Date(timeIntervalSince1970: 1_800_000_300))
        )
        let neverFetched = PresetResult(
            presetID: Self.presetB, accountID: Self.accountA, itemIDs: [], fetchedAt: nil, totalCount: 0,
            isComplete: false, selection: "selection-b",
            failure: PresetQueryFailure(code: "validation", at: Date(timeIntervalSince1970: 1_800_000_300))
        )
        let snapshot = Snapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_300), items: [],
                                presetResults: [fetched, neverFetched])

        let encoded = try SnapshotCoding.encode(snapshot)

        #expect(String(decoding: encoded, as: UTF8.self).contains(#""schemaVersion" : 2"#))
        #expect(try SnapshotCoding.decode(Snapshot.self, from: encoded) == snapshot)
    }

    @Test("preset results are written in the order of preset, then account")
    func resultsOrder() throws {
        func result(_ preset: UUID, _ account: UUID) -> PresetResult {
            PresetResult(presetID: preset, accountID: account, itemIDs: [], fetchedAt: nil, totalCount: 0,
                         isComplete: false, selection: "s")
        }
        let snapshot = Snapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), items: [], presetResults: [
            result(Self.presetB, Self.accountB), result(Self.presetA, Self.accountB),
            result(Self.presetB, Self.accountA), result(Self.presetA, Self.accountA),
        ])

        let decoded = try SnapshotCoding.decode(Snapshot.self, from: SnapshotCoding.encode(snapshot))

        #expect(decoded.presetResults.map { [$0.presetID, $0.accountID] } == [
            [Self.presetA, Self.accountA], [Self.presetA, Self.accountB],
            [Self.presetB, Self.accountA], [Self.presetB, Self.accountB],
        ])
    }

    // MARK: - Searched accounts

    @Test("a snapshot written before searched accounts existed loads with none, so every account reads all its items")
    func withoutSearchedAccounts() throws {
        let json = """
        {
          "schemaVersion": 2,
          "fetchedAt": "2026-09-10T06:35:00.000Z",
          "items": [],
          "accountStatus": {},
          "presetResults": []
        }
        """
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: Data(json.utf8))

        #expect(snapshot.searchedAccounts.isEmpty)
    }

    @Test("searched accounts are written in the order of their ids and read back unchanged")
    func searchedAccountsRoundTrip() throws {
        let snapshot = Snapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), items: [],
                                searchedAccounts: [Self.accountB, Self.accountA])

        let encoded = try SnapshotCoding.encode(snapshot)

        let text = String(decoding: encoded, as: UTF8.self)
        let first = try #require(text.range(of: Self.accountA.uuidString))
        let second = try #require(text.range(of: Self.accountB.uuidString))
        #expect(text.contains(#""searchedAccounts" : ["#))
        #expect(first.lowerBound < second.lowerBound)
        #expect(try SnapshotCoding.decode(Snapshot.self, from: encoded) == snapshot)
        // The same set gives the same bytes every time, whatever order the set iterates in.
        #expect(try SnapshotCoding.encode(Snapshot(fetchedAt: snapshot.fetchedAt, items: [],
                                                   searchedAccounts: [Self.accountA, Self.accountB])) == encoded)
    }

    @Test("work item id is stable and derived from account, repo, number and kind")
    func workItemID() throws {
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: Fixtures.data("snapshot.json"))
        let pr = try #require(snapshot.items.first { $0.kind == .pullRequest })
        #expect(pr.id == "8A2F7C1E-1111-2222-3333-444455556666/dxheroes/mcp-gateway#42/pullRequest")
        #expect(pr.id == WorkItem.makeID(accountID: pr.accountID, repoFullName: pr.repoFullName, number: pr.number, kind: pr.kind))
    }
}
