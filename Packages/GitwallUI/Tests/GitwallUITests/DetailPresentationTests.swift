import Foundation
import GitwallCore
import Testing
@testable import GitwallUI

@Suite("Detail presentation")
struct DetailPresentationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let me = UserRef(login: "prokop")

    private func pull(author: String = "jana", requested: [String] = []) -> WorkItem {
        WorkItem(accountID: UUID(), kind: .pullRequest, repoFullName: "acme/app", number: 7, title: "Change",
                 url: URL(string: "https://github.com/acme/app/pull/7")!, author: UserRef(login: author),
                 createdAt: now, updatedAt: now, requestedReviewers: requested.map { UserRef(login: $0) })
    }

    private func review(_ login: String, _ verdict: ReviewVerdict, minutes: Double) -> DetailReview {
        DetailReview(id: "\(login)\(minutes)", author: UserRef(login: login), verdict: verdict, body: "",
                     submittedAt: now.addingTimeInterval(minutes * 60), url: nil)
    }

    @Test("checks: failing ones by name, the rest counted")
    func checks() {
        let summary = DetailPresentation.CheckSummary([
            DetailCheck(name: "lint", state: .passed, url: nil),
            DetailCheck(name: "e2e", state: .failed, url: nil),
            DetailCheck(name: "unit", state: .passed, url: nil),
            DetailCheck(name: "deploy", state: .running, url: nil),
            DetailCheck(name: "docs", state: .skipped, url: nil),
        ])
        #expect(summary.failed.map(\.name) == ["e2e"])
        #expect(summary.running.map(\.name) == ["deploy"])
        #expect(summary.passed.map(\.name) == ["lint", "unit"])
        #expect(summary.skipped.map(\.name) == ["docs"])
        #expect(summary.passedLabel == "2 passed")
    }

    @Test("reviewers: the latest verdict per person, an approval outlives a later comment, the rest still requested")
    func reviewers() {
        let item = pull(requested: ["tomas", "mara"])
        let reviewers = DetailPresentation.reviewers(for: item, reviews: [
            review("mara", .approved, minutes: -30),
            review("mara", .commented, minutes: -10),
            review("ondrej", .changesRequested, minutes: -20),
            review("ondrej", .approved, minutes: -5),
            review("jana", .commented, minutes: -3),
            review("tomas", .pending, minutes: -1),
        ])
        #expect(reviewers == [
            .init(login: "mara", state: .approved),
            .init(login: "ondrej", state: .approved),
            .init(login: "tomas", state: .requested),
        ])
    }

    @Test("reviewers: one row per person whatever the case of the login or a [bot] suffix")
    func reviewersMatchLogins() {
        let item = pull(author: "Jana", requested: ["copilot-pull-request-reviewer"])
        let reviewers = DetailPresentation.reviewers(for: item, reviews: [
            review("mara", .approved, minutes: -30),
            review("Mara", .commented, minutes: -10),
            review("jana", .commented, minutes: -8),
            review("copilot-pull-request-reviewer[bot]", .commented, minutes: -5),
        ])
        #expect(reviewers == [
            .init(login: "mara", state: .approved),
            .init(login: "copilot-pull-request-reviewer[bot]", state: .commented),
        ])
    }

    @Test("a review without a summary says what it was")
    func silentReviews() {
        #expect(DetailPresentation.silentReview(.changesRequested, inlineCommentCount: 0) == "Requested changes")
        #expect(DetailPresentation.silentReview(.changesRequested, inlineCommentCount: 2) == "Requested changes with 2 inline comments")
        #expect(DetailPresentation.silentReview(.approved, inlineCommentCount: 0) == "Approved")
        #expect(DetailPresentation.silentReview(.approved, inlineCommentCount: 1) == "Approved with 1 inline comment")
        #expect(DetailPresentation.silentReview(.commented, inlineCommentCount: 4) == "Reviewed with 4 inline comments")
        #expect(DetailPresentation.silentReview(.commented, inlineCommentCount: 0) == "Reviewed")
        #expect(DetailPresentation.silentReview(.dismissed, inlineCommentCount: 0) == "Reviewed; the review was dismissed")
    }

    @Test("Why it's here names the preset only with the terms that matched")
    func whyItsHere() {
        let matched = DetailPresentation.WhyItsHere([.queryTerm("label:needs:approval"), .assignedToMe], presetName: "Čeká na mě")
        #expect(matched.presetLine == "Matches label:needs:approval in “Čeká na mě”")
        #expect(matched.terms == ["label:needs:approval"])
        #expect(matched.facts == [.assignedToMe])
        #expect(!matched.isEmpty)

        let bare = DetailPresentation.WhyItsHere([.assignedToMe], presetName: "All open")
        #expect(bare.presetLine == nil)
        #expect(bare.facts == [.assignedToMe])

        let nothing = DetailPresentation.WhyItsHere([], presetName: "All open")
        #expect(nothing.presetLine == nil)
        #expect(nothing.isEmpty)

        let terms = DetailPresentation.WhyItsHere([.queryTerm("is:pr"), .queryTerm("author:@me")], presetName: "Mine")
        #expect(terms.presetLine == "Matches is:pr author:@me in “Mine”")
    }

    @Test("ages read as a phrase; under a minute is just now, never now ago")
    func ages() {
        #expect(DetailPresentation.ago(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(DetailPresentation.ago(now.addingTimeInterval(-5 * 60), now: now) == "5m ago")
        #expect(DetailPresentation.ago(now.addingTimeInterval(-2 * 3600), now: now) == "2h ago")
        #expect(DetailPresentation.ago(now.addingTimeInterval(60), now: now) == "just now", "a clock ahead is not in the future")
    }

    @Test("an empty latest word says whether only bots spoke")
    func quietConversation() {
        let bot = DetailComment(id: "1", author: UserRef(login: "codecov"), authorIsBot: true, body: "Coverage 91%",
                                createdAt: now, url: nil)
        let app = DetailComment(id: "2", author: UserRef(login: "renovate[bot]"), body: "Update", createdAt: now, url: nil)
        #expect(DetailPresentation.quietConversation([]) == "No comments yet.")
        #expect(DetailPresentation.quietConversation([bot, app]) == "Only bots have commented.")
    }

    @Test("links open only on the web: http and https with a host")
    func openableLinks() throws {
        for link in ["https://github.com/acme/app/pull/7", "http://example.com/a", "HTTPS://example.com"] {
            #expect(DetailPresentation.isOpenable(try #require(URL(string: link))), "\(link)")
        }
        for link in ["javascript:alert(1)", "file:///etc/passwd", "x-gitwall://open", "mailto:a@b.c", "ssh://host/repo",
                     "https:relative", "/acme/app/issues/1", "#section"] {
            #expect(!DetailPresentation.isOpenable(try #require(URL(string: link))), "\(link)")
        }
    }

    @Test("reviewers before the reviews load come from the snapshot")
    func reviewersFromSnapshot() {
        var item = pull(requested: ["tomas"])
        item.reviewers = [UserRef(login: "mara")]
        #expect(DetailPresentation.reviewers(for: item, reviews: nil) == [
            .init(login: "mara", state: .reviewed),
            .init(login: "tomas", state: .requested),
        ])
    }

    @Test("events read as a sentence")
    func events() {
        func text(_ kind: TimelineEvent.Kind, by login: String? = "jana") -> String {
            DetailPresentation.describe(TimelineEvent(id: "1", kind: kind, actor: login.map { UserRef(login: $0) }, createdAt: now))
        }
        #expect(text(.commented) == "jana commented")
        #expect(text(.reviewed(.approved)) == "jana approved")
        #expect(text(.reviewed(.changesRequested)) == "jana requested changes")
        #expect(text(.reviewed(.commented)) == "jana reviewed")
        #expect(text(.committed(sha: "abc1234", message: "Fix the build")) == "jana pushed abc1234 Fix the build")
        #expect(text(.committed(sha: "abc1234", message: "Fix"), by: nil) == "Someone pushed abc1234 Fix")
        #expect(text(.labeled("bug")) == "jana added the label bug")
        #expect(text(.unlabeled("wip")) == "jana removed the label wip")
        #expect(text(.readyForReview) == "jana marked it ready for review")
        #expect(text(.reviewRequested("tomas")) == "jana requested a review from tomas")
        #expect(text(.assigned("prokop")) == "jana assigned prokop")
        #expect(text(.forcePushed(sha: "9f8e7d6")) == "jana force-pushed 9f8e7d6")
    }

    @Test("reasons and next steps say what they mean")
    func wording() {
        #expect(DetailPresentation.describe(.reviewRequestedFromMe, pullRequestTerm: "Pull request") == "Review requested from you")
        #expect(DetailPresentation.describe(.changesRequestedOnMyPullRequest, pullRequestTerm: "Merge request")
            == "Changes requested on your merge request")
        #expect(DetailPresentation.title(of: .reviewChanges, hostName: "GitHub") == "Review changes")
        #expect(DetailPresentation.title(of: .reply(to: "jana"), hostName: "GitHub") == "Reply to jana")
        #expect(DetailPresentation.title(of: .openFailingCheck("e2e"), hostName: "GitHub") == "Open failing check e2e")
        #expect(DetailPresentation.title(of: .openFailingCheck(nil), hostName: "GitHub") == "Open failing checks")
        #expect(DetailPresentation.title(of: .readyToMerge, hostName: "GitHub") == "Ready to merge")
        #expect(DetailPresentation.title(of: .open, hostName: "GitLab") == "Open on GitLab")
    }

    @Test("copy formats")
    func copies() {
        let item = pull()
        #expect(DetailPresentation.reference(of: item) == "acme/app#7")
        #expect(DetailPresentation.checkoutCommand(of: item, baseURL: URL(string: "https://github.com")) == "gh pr checkout 7 -R acme/app")
        #expect(DetailPresentation.checkoutCommand(of: item, baseURL: URL(string: "https://GitHub.com/")) == "gh pr checkout 7 -R acme/app")
        #expect(DetailPresentation.checkoutCommand(of: item, baseURL: nil) == "gh pr checkout 7 -R acme/app")
        #expect(DetailPresentation.checkoutCommand(of: item, baseURL: URL(string: "https://github.example.com"))
            == "gh pr checkout 7 -R github.example.com/acme/app")
    }
}
