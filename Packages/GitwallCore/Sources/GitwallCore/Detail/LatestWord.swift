import Foundation

/// Who is on turn: the last thing someone other than the signed-in account said, or that the account spoke last.
public enum LatestWord: Hashable, Sendable {
    case none
    case fromOther(Utterance)
    case youRepliedLast(at: Date)

    /// A comment or a review.
    public struct Utterance: Hashable, Sendable {
        public var author: UserRef
        /// Empty for a review without a summary; ``verdict`` and ``inlineCommentCount`` say what it was.
        public var body: String
        public var date: Date
        /// The comment or review itself, so Reply lands on it.
        public var url: URL?
        /// Nil for a comment.
        public var verdict: ReviewVerdict?
        public var inlineCommentCount: Int

        public init(author: UserRef, body: String, date: Date, url: URL?, verdict: ReviewVerdict?, inlineCommentCount: Int = 0) {
            self.author = author
            self.body = body
            self.date = date
            self.url = url
            self.verdict = verdict
            self.inlineCommentCount = inlineCommentCount
        }
    }

    /// Uses whatever parts of `detail` could be read.
    public static func find(in detail: ItemDetail, me: UserRef?) -> LatestWord {
        find(comments: (try? detail.comments.get()) ?? [], reviews: (try? detail.reviews.get()) ?? [], me: me)
    }

    /// Comments with a text and every submitted review count, a review without a summary too: a bare change request,
    /// an approval or inline comments are an answer. Pending reviews are drafts nobody else has seen, blank comments
    /// say nothing, and bots (a bot account, or a login ending in `[bot]`) never decide whose turn it is.
    /// A bot account, or a login ending in `[bot]`.
    public static func isBot(_ user: UserRef, flagged: Bool) -> Bool {
        flagged || user.login.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("[bot]")
    }

    public static func find(comments: [DetailComment], reviews: [DetailReview], me: UserRef?) -> LatestWord {
        func isMe(_ user: UserRef) -> Bool { me.map { LoginMatch.same($0.login, user.login) } ?? false }
        func hasText(_ body: String) -> Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var words = comments.filter { hasText($0.body) && !isBot($0.author, flagged: $0.authorIsBot) }.map {
            Utterance(author: $0.author, body: $0.body, date: $0.createdAt, url: $0.url, verdict: nil)
        }
        words += reviews.filter { $0.verdict != .pending && !isBot($0.author, flagged: $0.authorIsBot) }.map {
            Utterance(author: $0.author, body: $0.body, date: $0.submittedAt, url: $0.url, verdict: $0.verdict,
                      inlineCommentCount: $0.inlineCommentCount)
        }
        guard let last = words.max(by: { $0.date < $1.date }) else { return .none }
        return isMe(last.author) ? .youRepliedLast(at: last.date) : .fromOther(last)
    }
}
