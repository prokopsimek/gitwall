import Foundation
@testable import GitwallCore

/// Builders for Detail tests: one fixed clock, logins instead of full users.
enum DetailSupport {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let me = UserRef(login: "prokop")
    static let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub", me: me)

    static func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    static func pull(
        _ number: Int = 7,
        author: String = "jana",
        requested: [String] = [],
        assignees: [String] = [],
        review: ReviewState = .none,
        ci: CIState = .none,
        merge: MergeState = .clean,
        draft: Bool = false,
        account: Account = DetailSupport.account
    ) -> WorkItem {
        let path = account.kind == .github ? "pull" : "-/merge_requests"
        return WorkItem(
            accountID: account.id, kind: .pullRequest, repoFullName: "acme/app", number: number, title: "Change \(number)",
            url: account.baseURL.appendingPathComponent("acme/app/\(path)/\(number)"), author: UserRef(login: author),
            createdAt: at(minutes: -600), updatedAt: at(minutes: -5), isDraft: draft,
            assignees: assignees.map { UserRef(login: $0) },
            reviewState: review, ciState: ci, mergeState: merge,
            requestedReviewers: requested.map { UserRef(login: $0) }
        )
    }

    static func issue(_ number: Int = 8, author: String = "jana", assignees: [String] = []) -> WorkItem {
        WorkItem(
            accountID: account.id, kind: .issue, repoFullName: "acme/app", number: number, title: "Issue \(number)",
            url: URL(string: "https://github.com/acme/app/issues/\(number)")!, author: UserRef(login: author),
            createdAt: at(minutes: -600), updatedAt: at(minutes: -5), assignees: assignees.map { UserRef(login: $0) }
        )
    }

    static func comment(_ id: String, by login: String, minutes: Double, body: String = "Looks good") -> DetailComment {
        DetailComment(id: id, author: UserRef(login: login), body: body, createdAt: at(minutes: minutes),
                      url: URL(string: "https://github.com/acme/app/pull/7#issuecomment-\(id)"))
    }

    static func review(_ id: String, by login: String, _ verdict: ReviewVerdict, minutes: Double, body: String = "") -> DetailReview {
        DetailReview(id: id, author: UserRef(login: login), verdict: verdict, body: body, submittedAt: at(minutes: minutes),
                     url: URL(string: "https://github.com/acme/app/pull/7#pullrequestreview-\(id)"))
    }

    static func event(_ id: String, _ kind: TimelineEvent.Kind = .commented, by login: String?, minutes: Double) -> TimelineEvent {
        TimelineEvent(id: id, kind: kind, actor: login.map { UserRef(login: $0) }, createdAt: at(minutes: minutes))
    }

    static func detail(
        for item: WorkItem,
        comments: [DetailComment] = [],
        reviews: [DetailReview] = [],
        checks: [DetailCheck] = [],
        timeline: [TimelineEvent] = []
    ) -> ItemDetail {
        ItemDetail(itemID: item.id, itemUpdatedAt: item.updatedAt, fetchedAt: now,
                   comments: .success(comments), reviews: .success(reviews), timeline: .success(timeline),
                   checks: .success(checks))
    }
}
