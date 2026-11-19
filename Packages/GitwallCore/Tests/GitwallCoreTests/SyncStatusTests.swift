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

    // MARK: - Quiet period

    @Test("accounts riding out an outage show no failure, dated by the oldest last success among them")
    func quietSeries() {
        let status = SyncStatus(
            snapshot: snapshot(minutesAgo: 1, status: [
                github.id: FetchStatus(state: .ok, lastSuccessAt: now.addingTimeInterval(-10 * 60), consecutiveFailures: 1),
                gitlab.id: FetchStatus(state: .ok, lastSuccessAt: now.addingTimeInterval(-25 * 60), consecutiveFailures: 2),
                UUID(): FetchStatus(state: .ok, lastSuccessAt: now.addingTimeInterval(-3 * 3_600), consecutiveFailures: 1),
            ]),
            accounts: [github, gitlab],
            lastError: nil
        )
        #expect(!status.isFailure)
        #expect(status.text(now: now) == "Updated 25 min ago")
    }

    @Test("an account riding out an outage that never synced leaves the data undated")
    func quietSeriesNeverSynced() {
        let status = SyncStatus(
            snapshot: snapshot(minutesAgo: 1, status: [
                github.id: FetchStatus(state: .ok, lastSuccessAt: now.addingTimeInterval(-60)),
                gitlab.id: FetchStatus(state: .ok, lastSuccessAt: nil, consecutiveFailures: 1),
            ]),
            accounts: [github, gitlab],
            lastError: nil
        )
        #expect(!status.isFailure)
        #expect(status.text(now: now) == "Not updated yet")
    }

    @Test("the third failure in a row shows as a failure, dated by that account's last success")
    func thirdFailureInARow() {
        let status = SyncStatus(
            snapshot: snapshot(minutesAgo: 1, status: [
                github.id: FetchStatus(state: .error, lastSuccessAt: now.addingTimeInterval(-15 * 60),
                                       message: "Server error 503: Service Unavailable", consecutiveFailures: 3),
                gitlab.id: FetchStatus(state: .ok, lastSuccessAt: now.addingTimeInterval(-40 * 60), consecutiveFailures: 1),
            ]),
            accounts: [github, gitlab],
            lastError: nil
        )
        #expect(status.isFailure)
        #expect(status.text(now: now) == "Sync failed: GitHub (prokop): Server error 503: Service Unavailable · updated 15 min ago")
    }

    @Test("a sync that threw is dated by an account riding out an outage, not by the snapshot")
    func syncThrewDuringQuietSeries() {
        let status = SyncStatus(
            snapshot: snapshot(minutesAgo: 1, status: [
                github.id: FetchStatus(state: .ok, lastSuccessAt: now.addingTimeInterval(-40 * 60), consecutiveFailures: 2),
            ]),
            accounts: [github],
            lastError: "Offline"
        )
        #expect(status.text(now: now) == "Sync failed: Offline · updated 40 min ago")
    }

    @Test("an account that is not in the configuration any more does not count")
    func removedAccount() {
        let status = SyncStatus(snapshot: snapshot(minutesAgo: 1, status: [UUID(): FetchStatus(state: .error)]), accounts: [github], lastError: nil)
        #expect(!status.isFailure)
    }

    @Test("the age of any date reads as the status does, for other texts that say when something was fetched")
    func ageOfAnyDate() {
        #expect(SyncStatus.age(since: now.addingTimeInterval(-20), now: now) == "just now")
        #expect(SyncStatus.age(since: now.addingTimeInterval(-5 * 60), now: now) == "5 min ago")
        #expect(SyncStatus.age(since: now.addingTimeInterval(-185 * 60), now: now) == "3 h ago")
        #expect(SyncStatus.age(since: now.addingTimeInterval(-50 * 3_600), now: now) == "2 d ago")
        // A date ahead of the clock, as after a clock change, is just now rather than a negative age.
        #expect(SyncStatus.age(since: now.addingTimeInterval(90), now: now) == "just now")
    }
}
