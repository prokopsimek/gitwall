import Foundation

/// Who is on turn: the last thing someone other than the signed-in account said, or that the account spoke last.
public enum LatestWord: Hashable, Sendable {
    case none
    case fromOther(Utterance)
    case youRepliedLast(at: Date)

    /// A comment, or a review with a text.
    public struct Utterance: Hashable, Sendable {
        public var author: UserRef
        public var body: String
        public var date: Date
        /// The comment or review itself, so Reply lands on it.
        public var url: URL?
        /// Nil for a comment.
        public var verdict: ReviewVerdict?

        public init(author: UserRef, body: String, date: Date, url: URL?, verdict: ReviewVerdict?) {
            self.author = author
            self.body = body
            self.date = date
            self.url = url
            self.verdict = verdict
        }
    }

    /// Uses whatever parts of `detail` could be read.
    public static func find(in detail: ItemDetail, me: UserRef?) -> LatestWord {
        find(comments: (try? detail.comments.get()) ?? [], reviews: (try? detail.reviews.get()) ?? [], me: me)
    }

    /// Comments and reviews with a text count. A review of mine counts without one too: approving is an answer.
    /// Pending reviews are drafts nobody else has seen, and blank texts say nothing.
    public static func find(comments: [DetailComment], reviews: [DetailReview], me: UserRef?) -> LatestWord {
        func isMe(_ user: UserRef) -> Bool { me.map { LoginMatch.same($0.login, user.login) } ?? false }
        func hasText(_ body: String) -> Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var words = comments.filter { hasText($0.body) }.map {
            Utterance(author: $0.author, body: $0.body, date: $0.createdAt, url: $0.url, verdict: nil)
        }
        words += reviews.filter { $0.verdict != .pending && (hasText($0.body) || isMe($0.author)) }.map {
            Utterance(author: $0.author, body: $0.body, date: $0.submittedAt, url: $0.url, verdict: $0.verdict)
        }
        guard let last = words.max(by: { $0.date < $1.date }) else { return .none }
        return isMe(last.author) ? .youRepliedLast(at: last.date) : .fromOther(last)
    }
}
