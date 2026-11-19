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

    @Test("work item id is stable and derived from account, repo, number and kind")
    func workItemID() throws {
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: Fixtures.data("snapshot.json"))
        let pr = try #require(snapshot.items.first { $0.kind == .pullRequest })
        #expect(pr.id == "8A2F7C1E-1111-2222-3333-444455556666/dxheroes/mcp-gateway#42/pullRequest")
        #expect(pr.id == WorkItem.makeID(accountID: pr.accountID, repoFullName: pr.repoFullName, number: pr.number, kind: pr.kind))
    }
}
