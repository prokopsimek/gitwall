import Foundation

/// Why an item is in front of someone: what Detail lists under "Why it's here".
public enum MatchReason: Hashable, Sendable {
    /// A term of the preset's query the item satisfied, as written (`label:bug`, `review-requested:@me`).
    case queryTerm(String)
    case reviewRequestedFromMe
    case assignedToMe
    case changesRequestedOnMyPullRequest
    case failingChecks
    case mergeConflict
}

extension FilterEngine {
    /// The terms of `query` the item satisfied (see ``SearchQuery``), then the facts about the item that hold
    /// whatever the query says. A query the item does not match, or cannot be read, contributes no terms.
    public static func explain(_ item: WorkItem, query: String?, me: UserRef?) -> [MatchReason] {
        var reasons: [MatchReason] = []
        if let query, case .success(let parsed) = SearchQuery.parse(query) {
            reasons += (parsed.explanation(for: item, me: me) ?? []).map(MatchReason.queryTerm)
        }

        func isMe(_ user: UserRef) -> Bool { me.map { LoginMatch.same($0.login, user.login) } ?? false }
        let isPullRequest = item.kind == .pullRequest
        if isPullRequest, item.requestedReviewers.contains(where: isMe) { reasons.append(.reviewRequestedFromMe) }
        if item.assignees.contains(where: isMe) { reasons.append(.assignedToMe) }
        if isPullRequest, isMe(item.author), item.reviewState == .changesRequested { reasons.append(.changesRequestedOnMyPullRequest) }
        if isPullRequest, item.ciState == .failure { reasons.append(.failingChecks) }
        if isPullRequest, item.mergeState == .conflict { reasons.append(.mergeConflict) }
        return reasons
    }
}
