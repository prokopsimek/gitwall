import Foundation
import GitwallCore

/// Pure wording and grouping for ``DetailView``, kept apart from the view so it can be tested.
public enum DetailPresentation {
    /// Failing checks by name, the rest grouped; Detail lists the first and counts the others.
    public struct CheckSummary: Hashable, Sendable {
        public var failed: [DetailCheck]
        public var running: [DetailCheck]
        public var passed: [DetailCheck]
        public var skipped: [DetailCheck]

        public init(_ checks: [DetailCheck]) {
            failed = checks.filter { $0.state == .failed }
            running = checks.filter { $0.state == .running }
            passed = checks.filter { $0.state == .passed }
            skipped = checks.filter { $0.state == .skipped }
        }

        public var passedLabel: String { "\(passed.count) passed" }
    }

    public struct Reviewer: Hashable, Sendable, Identifiable {
        public enum State: Hashable, Sendable {
            case approved, changesRequested, commented, dismissed
            /// Reviewed, verdict unknown until the reviews load.
            case reviewed
            /// Asked to review, has not yet.
            case requested
        }

        public var id: String { login }
        public var login: String
        public var state: State

        public init(login: String, state: State) {
            self.login = login
            self.state = state
        }
    }

    /// One row per reviewer: the latest approval, change request or dismissal, which a later plain comment does not
    /// replace (as on GitHub), else a comment; then everyone still asked. The author's own comments are no review.
    /// Logins match as ``LoginMatch`` says, and a row keeps the spelling of the person's first review.
    /// `reviews` is nil until they load, and the snapshot's reviewers stand in.
    public static func reviewers(for item: WorkItem, reviews: [DetailReview]?) -> [Reviewer] {
        var result: [Reviewer] = []
        if let reviews {
            for review in reviews.sorted(by: { $0.submittedAt < $1.submittedAt })
            where !LoginMatch.same(review.author.login, item.author.login) {
                let row = result.firstIndex { LoginMatch.same($0.login, review.author.login) }
                let state: Reviewer.State
                switch review.verdict {
                case .pending: continue
                case .approved: state = .approved
                case .changesRequested: state = .changesRequested
                case .dismissed: state = .dismissed
                case .commented:
                    if let row, result[row].state != .commented { continue }
                    state = .commented
                }
                if let row { result[row].state = state } else { result.append(Reviewer(login: review.author.login, state: state)) }
            }
        } else {
            result = item.reviewers.map { Reviewer(login: $0.login, state: .reviewed) }
        }
        for requested in item.requestedReviewers where !result.contains(where: { LoginMatch.same($0.login, requested.login) }) {
            result.append(Reviewer(login: requested.login, state: .requested))
        }
        return result
    }

    public static func describe(_ event: TimelineEvent) -> String {
        let who = event.actor?.login ?? "Someone"
        return switch event.kind {
        case .commented: "\(who) commented"
        case .reviewed(.approved): "\(who) approved"
        case .reviewed(.changesRequested): "\(who) requested changes"
        case .reviewed(.dismissed): "\(who)'s review was dismissed"
        case .reviewed: "\(who) reviewed"
        case .committed(let sha, let message): "\(who) pushed \(sha) \(message)"
        case .labeled(let label): "\(who) added the label \(label)"
        case .unlabeled(let label): "\(who) removed the label \(label)"
        case .readyForReview: "\(who) marked it ready for review"
        case .reviewRequested(let reviewer): "\(who) requested a review from \(reviewer)"
        case .assigned(let assignee): "\(who) assigned \(assignee)"
        case .forcePushed(let sha): sha.map { "\(who) force-pushed \($0)" } ?? "\(who) force-pushed"
        }
    }

    public static func symbol(for event: TimelineEvent) -> String {
        switch event.kind {
        case .commented: "bubble.left"
        case .reviewed(.approved): "checkmark.circle"
        case .reviewed(.changesRequested): "xmark.circle"
        case .reviewed: "eye"
        case .committed: "smallcircle.filled.circle"
        case .labeled, .unlabeled: "tag"
        case .readyForReview: "eye"
        case .reviewRequested: "person.crop.circle.badge.questionmark"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .forcePushed: "arrow.triangle.2.circlepath"
        }
    }

    public static func describe(_ reason: MatchReason, pullRequestTerm: String) -> String {
        switch reason {
        case .queryTerm(let term): term
        case .reviewRequestedFromMe: "Review requested from you"
        case .assignedToMe: "Assigned to you"
        case .changesRequestedOnMyPullRequest: "Changes requested on your \(pullRequestTerm.lowercased())"
        case .failingChecks: "Checks are failing"
        case .mergeConflict: "Merge conflict"
        }
    }

    public static func symbol(for reason: MatchReason) -> String {
        switch reason {
        case .queryTerm: "line.3.horizontal.decrease"
        case .reviewRequestedFromMe: "eye"
        case .assignedToMe: "person.crop.circle.badge.checkmark"
        case .changesRequestedOnMyPullRequest: "xmark.circle"
        case .failingChecks: "exclamationmark.triangle"
        case .mergeConflict: "arrow.triangle.merge"
        }
    }

    public static func title(of action: NextStep.Action, hostName: String) -> String {
        switch action {
        case .reviewChanges: "Review changes"
        case .reply(let login): "Reply to \(login)"
        case .openFailingCheck(let name?): "Open failing check \(name)"
        case .openFailingCheck(nil): "Open failing checks"
        case .readyToMerge: "Ready to merge"
        case .open: "Open on \(hostName)"
        }
    }

    /// What a review without a summary was: a bare approval or change request, or only inline comments.
    public static func silentReview(_ verdict: ReviewVerdict, inlineCommentCount: Int) -> String {
        let inline = switch inlineCommentCount {
        case 0: ""
        case 1: " with 1 inline comment"
        default: " with \(inlineCommentCount) inline comments"
        }
        return switch verdict {
        case .approved: "Approved\(inline)"
        case .changesRequested: "Requested changes\(inline)"
        case .commented: "Reviewed\(inline)"
        case .dismissed: "Reviewed\(inline); the review was dismissed"
        case .pending: "Started a review\(inline)"
        }
    }

    /// "Why it's here": the preset's line only when terms of its query matched (`Matches label:bug in “Bugs”`), then
    /// the facts that hold whatever the preset says.
    public struct WhyItsHere: Hashable, Sendable {
        public var terms: [String]
        public var presetName: String?
        public var facts: [MatchReason]

        public init(_ reasons: [MatchReason], presetName: String?) {
            terms = reasons.compactMap { if case .queryTerm(let term) = $0 { term } else { nil } }
            facts = reasons.filter { if case .queryTerm = $0 { false } else { true } }
            self.presetName = presetName
        }

        public var presetLine: String? {
            guard let presetName, !terms.isEmpty else { return nil }
            return "Matches \(terms.joined(separator: " ")) in “\(presetName)”"
        }

        public var isEmpty: Bool { presetLine == nil && facts.isEmpty }
    }

    /// Links in someone else's text open only when they lead to a web page; `javascript:`, `file:`, app schemes and
    /// links without a host never reach the system.
    public static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// `owner/repo#123`, for Copy Reference.
    public static func reference(of item: WorkItem) -> String {
        "\(item.repoFullName)#\(item.number)"
    }

    /// For Copy `gh pr checkout`; GitHub pull requests only. `baseURL` is the account's: on GitHub Enterprise `gh`
    /// needs the host in front of the repository.
    public static func checkoutCommand(of item: WorkItem, baseURL: URL?) -> String {
        let host = baseURL?.host?.lowercased() ?? "github.com"
        let repository = host == "github.com" ? item.repoFullName : "\(host)/\(item.repoFullName)"
        return "gh pr checkout \(item.number) -R \(repository)"
    }
}
