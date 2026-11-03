import Foundation
import Testing
@testable import GitwallCore

@Suite("LatestWord")
struct LatestWordTests {
    typealias S = DetailSupport

    @Test("the newest comment or review with a text from someone else")
    func newestFromSomeoneElse() throws {
        let latest = LatestWord.find(
            comments: [S.comment("1", by: "jana", minutes: -50), S.comment("2", by: "tomas", minutes: -20, body: "One more thing")],
            reviews: [S.review("r1", by: "mara", .commented, minutes: -30, body: "Nit")],
            me: S.me
        )

        guard case .fromOther(let word) = latest else {
            Issue.record("expected a word from someone else, got \(latest)")
            return
        }
        #expect(word.author.login == "tomas")
        #expect(word.body == "One more thing")
        #expect(word.date == S.at(minutes: -20))
        #expect(word.url == URL(string: "https://github.com/acme/app/pull/7#issuecomment-2"))
        #expect(word.verdict == nil)
    }

    @Test("a review counts as the latest word and keeps its verdict")
    func reviewIsAWord() throws {
        let latest = LatestWord.find(
            comments: [S.comment("1", by: "jana", minutes: -50)],
            reviews: [S.review("r1", by: "mara", .changesRequested, minutes: -10, body: "Please split this")],
            me: S.me
        )

        guard case .fromOther(let word) = latest else {
            Issue.record("expected a review, got \(latest)")
            return
        }
        #expect(word.author.login == "mara")
        #expect(word.verdict == .changesRequested)
    }

    @Test("when I spoke last it says so instead of quoting anyone")
    func iRepliedLast() {
        let latest = LatestWord.find(
            comments: [S.comment("1", by: "jana", minutes: -50), S.comment("2", by: "Prokop", minutes: -10)],
            reviews: [],
            me: S.me
        )

        #expect(latest == .youRepliedLast(at: S.at(minutes: -10)))
    }

    @Test("my approval without a text is a reply too")
    func myBareApprovalIsAReply() {
        let latest = LatestWord.find(
            comments: [S.comment("1", by: "jana", minutes: -50)],
            reviews: [S.review("r1", by: "prokop", .approved, minutes: -5)],
            me: S.me
        )

        #expect(latest == .youRepliedLast(at: S.at(minutes: -5)))
    }

    @Test("reviews without a text from others, blank comments and pending reviews say nothing")
    func silentEntries() {
        let latest = LatestWord.find(
            comments: [S.comment("1", by: "jana", minutes: -50), S.comment("2", by: "tomas", minutes: -10, body: "  \n")],
            reviews: [S.review("r1", by: "mara", .approved, minutes: -5), S.review("r2", by: "prokop", .pending, minutes: -1, body: "draft")],
            me: S.me
        )

        guard case .fromOther(let word) = latest else {
            Issue.record("expected Jana's comment, got \(latest)")
            return
        }
        #expect(word.author.login == "jana")
    }

    @Test("nothing said yet")
    func nothing() {
        #expect(LatestWord.find(comments: [], reviews: [], me: S.me) == .none)
    }

    @Test("without a known identity everyone is someone else")
    func noIdentity() {
        let latest = LatestWord.find(comments: [S.comment("1", by: "prokop", minutes: -1)], reviews: [], me: nil)
        guard case .fromOther = latest else {
            Issue.record("expected a word from someone else, got \(latest)")
            return
        }
    }

    @Test("reads what a detail could load and ignores a part that failed")
    func fromDetail() {
        let item = S.pull()
        var detail = S.detail(for: item, comments: [S.comment("1", by: "jana", minutes: -50)])
        detail.reviews = .failure(.missingPermission)

        guard case .fromOther(let word) = LatestWord.find(in: detail, me: S.me) else {
            Issue.record("expected Jana's comment")
            return
        }
        #expect(word.author.login == "jana")
    }
}
