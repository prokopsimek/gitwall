import Foundation

/// The one thing Detail suggests doing about an item, with the exact place on the provider to do it. Gitwall stays
/// read-only: every step opens a page. The rules are generic on purpose; no team's labels or habits are in here.
public struct NextStep: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        /// A review is requested from the signed-in account.
        case reviewChanges
        /// Someone else spoke last; the login is theirs.
        case reply(to: String)
        /// The account's own pull request fails a check; the name when Detail knows it.
        case openFailingCheck(String?)
        /// Approved, checks passed, no conflict.
        case readyToMerge
        case open
    }

    public var action: Action
    public var url: URL

    public init(action: Action, url: URL) {
        self.action = action
        self.url = url
    }

    /// The first rule that applies, in this order: a review requested from me, someone else's latest word, failing
    /// checks on my pull request, ready to merge, and otherwise just open it. `detail` may be nil while it loads or
    /// for a provider without Detail; the rules that need it are skipped.
    public static func suggest(for item: WorkItem, detail: ItemDetail?, me: UserRef?, provider: ProviderKind) -> NextStep {
        func isMe(_ user: UserRef) -> Bool { me.map { LoginMatch.same($0.login, user.login) } ?? false }
        let isPullRequest = item.kind == .pullRequest

        if isPullRequest, item.requestedReviewers.contains(where: isMe) {
            return NextStep(action: .reviewChanges, url: item.url.appendingPathComponent(provider == .gitlab ? "diffs" : "files"))
        }
        if let detail, case .fromOther(let word) = LatestWord.find(in: detail, me: me) {
            return NextStep(action: .reply(to: word.author.login), url: word.url ?? item.url)
        }
        let failing = ((try? detail?.checks.get()) ?? []).first { $0.state == .failed }
        if isPullRequest, isMe(item.author), item.ciState == .failure || failing != nil {
            let checksPage = item.url.appendingPathComponent(provider == .gitlab ? "pipelines" : "checks")
            return NextStep(action: .openFailingCheck(failing?.name), url: failing?.url ?? checksPage)
        }
        if isPullRequest, !item.isDraft, item.reviewState == .approved, item.ciState == .success, item.mergeState == .clean {
            return NextStep(action: .readyToMerge, url: item.url)
        }
        return NextStep(action: .open, url: item.url)
    }
}
