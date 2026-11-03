import Foundation
import GitwallCore
import Testing

/// Detail must render without a network in sample data and in `--debug-demo`, so the sample items carry one.
@Suite("DemoData · Detail")
struct DemoDetailTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ repo: String, _ number: Int) throws -> WorkItem {
        try #require(DemoData.snapshot(now: now).items.first { $0.repoFullName == repo && $0.number == number })
    }

    @Test("every sample item has a detail of its own state; other items have none")
    func everyItem() throws {
        for item in DemoData.snapshot(now: now, arrivals: DemoData.arrivalCount).items {
            let detail = try #require(DemoData.detail(for: item), "no detail for \(item.repoFullName)#\(item.number)")
            #expect(detail.itemID == item.id)
            #expect(detail.itemUpdatedAt == item.updatedAt)
            #expect(detail.failures.isEmpty)
        }
        let foreign = WorkItem(accountID: UUID(), kind: .issue, repoFullName: "a/b", number: 1, title: "x",
                               url: URL(string: "https://example.com")!, author: UserRef(login: "x"), createdAt: now, updatedAt: now)
        #expect(DemoData.detail(for: foreign) == nil)
    }

    @Test("the infra pull request shows a failing check, a review requested from me and an agent's plan")
    func richPullRequest() throws {
        let item = try item("northwind/infra", 97)
        let detail = try #require(DemoData.detail(for: item))

        #expect(item.requestedReviewers.contains(DemoData.me))
        let checks = try detail.checks.get()
        #expect(checks.filter { $0.state == .failed }.count == 1)
        #expect(checks.filter { $0.state == .passed }.count >= 10)
        let comments = try detail.comments.get()
        #expect(comments.contains { $0.body.contains("<details>") && $0.body.contains("| Step |") })
        #expect(try detail.branches.get() != nil)
        #expect(try detail.files.get().files.count > 3)
        #expect(try detail.timeline.get().contains { $0.kind == .reviewRequested(DemoData.me.login) })
        #expect(try detail.timeline.get().allSatisfy { $0.createdAt <= item.updatedAt })
        #expect(NextStep.suggest(for: item, detail: detail, me: DemoData.me, provider: .github).action == .reviewChanges)
    }

    @Test("the P0 issue has a conversation where someone else spoke last and a pull request that closes it")
    func richIssue() throws {
        let item = try item("northwind/storefront", 1287)
        let detail = try #require(DemoData.detail(for: item))

        guard case .fromOther = LatestWord.find(in: detail, me: DemoData.me) else {
            Issue.record("expected someone else to have the latest word")
            return
        }
        #expect(try detail.linkedItems.get().map(\.kind) == [.pullRequest])
        #expect(try detail.body.get().contains("## Steps to reproduce"))
    }
}
