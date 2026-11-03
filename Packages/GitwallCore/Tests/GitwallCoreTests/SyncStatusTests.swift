import Foundation
import Testing
@testable import GitwallCore

@Suite("Sync status")
struct SyncStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let github = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub (prokop)")
    let gitlab = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, displayName: "GitLab (prokop)")

    private func snapshot(minutesAgo: Double, status: [UUID: FetchStatus] = [:]) -> Snapshot {
        Snapshot(fetchedAt: now.addingTimeInterval(-minutesAgo * 60), items: [], accountStatus: status)
    }

    @Test("a healthy sync says how long ago it was")
    func healthy() {
        let status = SyncStatus(snapshot: snapshot(minutesAgo: 2), accounts: [github], lastError: nil)
        #expect(!status.isFailure)
        #expect(status.text(now: now) == "Updated 2 min ago")
        #expect(SyncStatus(snapshot: snapshot(minutesAgo: 0.2), accounts: [], lastError: nil).text(now: now) == "Updated just now")
        #expect(SyncStatus(snapshot: snapshot(minutesAgo: 185), accounts: [], lastError: nil).text(now: now) == "Updated 3 h ago")
        #expect(SyncStatus(snapshot: snapshot(minutesAgo: 60 * 50), accounts: [], lastError: nil).text(now: now) == "Updated 2 d ago")
    }

    @Test("nothing synced yet says so")
    func never() {
        let status = SyncStatus(snapshot: nil, accounts: [], lastError: nil)
        #expect(!status.isFailure)
        #expect(status.text(now: now) == "Not updated yet")
    }

    @Test("a failed sync is a failure with its reason and the age of the data")
    func syncThrew() {
        let status = SyncStatus(snapshot: snapshot(minutesAgo: 30), accounts: [github], lastError: "The Internet connection appears to be offline.")
        #expect(status.isFailure)
        #expect(status.text(now: now) == "Sync failed: The Internet connection appears to be offline. · updated 30 min ago")
        #expect(SyncStatus(snapshot: nil, accounts: [], lastError: "Offline").text(now: now) == "Sync failed: Offline")
    }

    @Test("an account that failed names itself, and its own last success dates the data")
    func accountFailed() {
        let status = SyncStatus(
            snapshot: snapshot(minutesAgo: 1, status: [
                github.id: FetchStatus(state: .ok, lastSuccessAt: now),
                gitlab.id: FetchStatus(state: .needsReauth, lastSuccessAt: now.addingTimeInterval(-7_200), message: "Bad credentials"),
            ]),
            accounts: [github, gitlab],
            lastError: nil
        )
        #expect(status.isFailure)
        #expect(status.text(now: now) == "Sync failed: GitLab (prokop): Bad credentials · updated 2 h ago")

        let unexplained = SyncStatus(
            snapshot: snapshot(minutesAgo: 1, status: [github.id: FetchStatus(state: .rateLimited)]),
            accounts: [github],
            lastError: nil
        )
        #expect(unexplained.text(now: now) == "Sync failed: GitHub (prokop): rate limited")
    }

    @Test("an account that is not in the configuration any more does not count")
    func removedAccount() {
        let status = SyncStatus(snapshot: snapshot(minutesAgo: 1, status: [UUID(): FetchStatus(state: .error)]), accounts: [github], lastError: nil)
        #expect(!status.isFailure)
    }
}
