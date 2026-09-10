import Foundation
import Testing
@testable import GitwallCore

@Suite("SnapshotDiff")
struct SnapshotDiffTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub", me: UserRef(login: "me"))

    private func item(_ n: Int, kind: ItemKind = .pullRequest, reviewState: ReviewState? = ReviewState.none, ciState: CIState? = CIState.none, requested: [String] = []) -> WorkItem {
        WorkItem(accountID: account.id, kind: kind, repoFullName: "acme/app", number: n, title: "Item \(n)",
                 url: URL(string: "https://example.com/\(n)")!, author: UserRef(login: "x"),
                 createdAt: now, updatedAt: now,
                 reviewState: kind == .pullRequest ? reviewState : nil,
                 ciState: kind == .pullRequest ? ciState : nil,
                 requestedReviewers: requested.map { UserRef(login: $0) })
    }

    private func snapshot(_ items: [WorkItem]) -> Snapshot { Snapshot(fetchedAt: now, items: items) }

    private func events(_ previous: [WorkItem]?, _ current: [WorkItem]) -> [Int: [NotificationEvent]] {
        let changes = SnapshotDiff.changes(from: previous.map(snapshot), to: snapshot(current), accounts: [account])
        return Dictionary(grouping: changes, by: { $0.item.number }).mapValues { $0.map(\.event).sorted { $0.rawValue < $1.rawValue } }
    }

    @Test("the first sync produces no changes")
    func firstSync() {
        #expect(events(nil, [item(1)]).isEmpty)
    }

    @Test("new items are reported once")
    func newItems() {
        #expect(events([item(1)], [item(1), item(2)]) == [2: [.newItem]])
    }

    @Test("review requested for me is detected when I appear among requested reviewers")
    func reviewRequested() {
        #expect(events([item(1)], [item(1, requested: ["me"])]) == [1: [.reviewRequested]])
        #expect(events([item(1, requested: ["me"])], [item(1, requested: ["me"])]).isEmpty)
        #expect(events([item(1)], [item(1, requested: ["other"])]).isEmpty)
    }

    @Test("review decision transitions")
    func reviewDecision() {
        #expect(events([item(1)], [item(1, reviewState: .approved)]) == [1: [.approved]])
        #expect(events([item(1)], [item(1, reviewState: .changesRequested)]) == [1: [.changesRequested]])
        #expect(events([item(1, reviewState: .approved)], [item(1, reviewState: .approved)]).isEmpty)
    }

    @Test("CI failure is reported on transition only")
    func ciFailed() {
        #expect(events([item(1, ciState: .running)], [item(1, ciState: .failure)]) == [1: [.ciFailed]])
        #expect(events([item(1, ciState: .failure)], [item(1, ciState: .failure)]).isEmpty)
    }

    @Test("items that disappear are reported as closed")
    func closed() {
        #expect(events([item(1), item(2)], [item(1)]) == [2: [.closed]])
    }

    @Test("a brand new item with a review request reports both events")
    func newWithRequest() {
        #expect(events([], [item(1, requested: ["me"])]) == [1: [.newItem, .reviewRequested]])
    }

    @Test("changes are matched against presets to decide what to notify")
    func presetRouting() {
        let mine = Preset(name: "Review", filter: ItemFilter(relations: [.reviewRequestedFromMe]), notifications: [.reviewRequested])
        let quiet = Preset(name: "All", notifications: [])
        let changes = SnapshotDiff.changes(from: snapshot([item(1)]), to: snapshot([item(1, requested: ["me"]), item(2)]), accounts: [account])
        let routed = SnapshotDiff.notifications(for: changes, presets: [mine, quiet], accounts: [account], previous: snapshot([item(1)]), now: now)
        #expect(routed.map { ($0.change.item.number, $0.change.event, $0.preset.id) }.map { "\($0.0)-\($0.1)-\($0.2)" } == ["1-reviewRequested-\(mine.id)"])
    }

    @Test("closed items are routed using the preset match of their previous state")
    func closedRouting() {
        let all = Preset(name: "All", notifications: [.closed])
        let previous = snapshot([item(1), item(2)])
        let changes = SnapshotDiff.changes(from: previous, to: snapshot([item(1)]), accounts: [account])
        let routed = SnapshotDiff.notifications(for: changes, presets: [all], accounts: [account], previous: previous, now: now)
        #expect(routed.map(\.change.item.number) == [2])
    }
}
