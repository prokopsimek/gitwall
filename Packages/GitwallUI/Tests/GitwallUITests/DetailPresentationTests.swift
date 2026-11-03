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
        #expect(DetailPresentation.checkoutCommand(of: item) == "gh pr checkout 7 -R acme/app")
    }
}
