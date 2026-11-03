import Foundation
import Testing
@testable import GitwallCore

@Suite("NextStep")
struct NextStepTests {
    typealias S = DetailSupport

    private let gitlab = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, displayName: "GitLab", me: DetailSupport.me)

    @Test("a review requested from me leads to the changes")
    func reviewChanges() {
        let item = S.pull(requested: ["Prokop"])
        let detail = S.detail(for: item, comments: [S.comment("1", by: "jana", minutes: -1)])

        let step = NextStep.suggest(for: item, detail: detail, me: S.me, provider: .github)

        #expect(step == NextStep(action: .reviewChanges, url: URL(string: "https://github.com/acme/app/pull/7/files")!))
    }

    @Test("on GitLab the changes are the Changes tab")
    func reviewChangesOnGitLab() {
        let item = S.pull(requested: ["prokop"], account: gitlab)

        let step = NextStep.suggest(for: item, detail: nil, me: S.me, provider: .gitlab)

        #expect(step.url == URL(string: "https://gitlab.com/acme/app/-/merge_requests/7/diffs"))
    }

    @Test("when someone else spoke last, reply right at their comment")
    func reply() {
        let item = S.issue()
        let detail = S.detail(for: item, comments: [S.comment("1", by: "prokop", minutes: -30), S.comment("2", by: "jana", minutes: -3)])

        let step = NextStep.suggest(for: item, detail: detail, me: S.me, provider: .github)

        #expect(step == NextStep(action: .reply(to: "jana"), url: URL(string: "https://github.com/acme/app/pull/7#issuecomment-2")!))
    }

    @Test("failing checks on my pull request lead to the first failing check")
    func failingCheck() {
        let item = S.pull(author: "prokop", ci: .failure)
        let detail = S.detail(for: item, comments: [S.comment("1", by: "prokop", minutes: -3)], checks: [
            DetailCheck(name: "lint", state: .passed, url: URL(string: "https://ci.example/lint")),
            DetailCheck(name: "unit (linux)", state: .failed, url: URL(string: "https://ci.example/unit")),
            DetailCheck(name: "unit (macOS)", state: .failed, url: URL(string: "https://ci.example/mac")),
        ])

        let step = NextStep.suggest(for: item, detail: detail, me: S.me, provider: .github)

        #expect(step == NextStep(action: .openFailingCheck("unit (linux)"), url: URL(string: "https://ci.example/unit")!))
    }

    @Test("before the checks are known, a failing pull request of mine opens its checks page")
    func failingCheckWithoutDetail() {
        let item = S.pull(author: "prokop", ci: .failure)

        let step = NextStep.suggest(for: item, detail: nil, me: S.me, provider: .github)

        #expect(step == NextStep(action: .openFailingCheck(nil), url: URL(string: "https://github.com/acme/app/pull/7/checks")!))
    }

    @Test("approved, green and without a conflict is ready to merge")
    func readyToMerge() {
        let item = S.pull(author: "prokop", review: .approved, ci: .success, merge: .clean)

        let step = NextStep.suggest(for: item, detail: S.detail(for: item), me: S.me, provider: .github)

        #expect(step == NextStep(action: .readyToMerge, url: item.url))
    }

    @Test("a draft, a conflict or a check still running is not ready to merge", arguments: [
        DetailSupport.pull(author: "prokop", review: .approved, ci: .success, draft: true),
        DetailSupport.pull(author: "prokop", review: .approved, ci: .success, merge: .conflict),
        DetailSupport.pull(author: "prokop", review: .approved, ci: .running),
        DetailSupport.pull(author: "prokop", review: .pending, ci: .success),
    ])
    func notReady(item: WorkItem) {
        #expect(NextStep.suggest(for: item, detail: nil, me: S.me, provider: .github) == NextStep(action: .open, url: item.url))
    }

    @Test("someone else's failing pull request just opens")
    func othersFailingPullRequest() {
        let item = S.pull(author: "jana", ci: .failure)
        #expect(NextStep.suggest(for: item, detail: nil, me: S.me, provider: .github).action == .open)
    }

    @Test("the review request wins over everything; on my own pull request a failing check wins over a reply")
    func order() {
        let mine = S.pull(author: "prokop", requested: ["prokop"], ci: .failure)
        let words = S.detail(for: mine, comments: [S.comment("1", by: "jana", minutes: -1)])
        #expect(NextStep.suggest(for: mine, detail: words, me: S.me, provider: .github).action == .reviewChanges)

        let failing = S.pull(author: "prokop", ci: .failure)
        let reply = S.detail(for: failing, comments: [S.comment("1", by: "jana", minutes: -1)])
        #expect(NextStep.suggest(for: failing, detail: reply, me: S.me, provider: .github).action == .openFailingCheck(nil))

        let green = S.pull(author: "prokop", ci: .success)
        let question = S.detail(for: green, comments: [S.comment("1", by: "jana", minutes: -1)])
        #expect(NextStep.suggest(for: green, detail: question, me: S.me, provider: .github).action == .reply(to: "jana"))
    }

    @Test("a bot's comment is no reason to reply")
    func botsAreNoReason() {
        let item = S.issue()
        var bot = S.comment("2", by: "codecov", minutes: -1)
        bot.authorIsBot = true
        let detail = S.detail(for: item, comments: [bot, S.comment("3", by: "dependabot[bot]", minutes: 0)])

        #expect(NextStep.suggest(for: item, detail: detail, me: S.me, provider: .github).action == .open)
    }
}
