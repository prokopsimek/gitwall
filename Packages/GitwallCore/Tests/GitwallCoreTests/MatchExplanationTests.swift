import Foundation
import Testing
@testable import GitwallCore

@Suite("FilterEngine.explain")
struct MatchExplanationTests {
    typealias S = DetailSupport

    private func item(labels: [String] = [], author: String = "jana", requested: [String] = [], assignees: [String] = [],
                      review: ReviewState = .none, ci: CIState = .none, merge: MergeState = .clean, draft: Bool = false) -> WorkItem {
        var item = S.pull(author: author, requested: requested, assignees: assignees, review: review, ci: ci, merge: merge, draft: draft)
        item.labels = labels.map { Label(name: $0) }
        return item
    }

    private func terms(_ item: WorkItem, _ query: String) -> [String] {
        FilterEngine.explain(item, query: query, me: S.me).compactMap {
            if case .queryTerm(let term) = $0 { return term }
            return nil
        }
    }

    @Test("every term of an AND that the item satisfied, in the order written")
    func and() {
        let item = item(labels: ["bug"], requested: ["prokop"])
        #expect(terms(item, "is:pr label:bug review-requested:@me") == ["is:pr", "label:bug", "review-requested:@me"])
        #expect(terms(item, "label:bug AND is:open") == ["label:bug", "is:open"])
    }

    @Test("only the branch of an OR that matched, the first one when several do")
    func or() {
        let item = item(labels: ["needs:approval"])
        #expect(terms(item, "review-requested:@me OR label:needs:approval") == ["label:needs:approval"])
        #expect(terms(item, "label:needs:approval OR is:pr") == ["label:needs:approval"])
    }

    @Test("parentheses nest")
    func groups() {
        let item = item(labels: ["bug"], author: "renovate[bot]")
        #expect(terms(item, "author:renovate (label:security OR label:bug)") == ["author:renovate", "label:bug"])
        #expect(terms(item, "involves:jana (label:needs:approval OR (review-requested:@me -is:draft))") == [])
    }

    @Test("a negated term explains nothing, but must still hold")
    func negation() {
        #expect(terms(item(labels: ["bug"]), "label:bug -is:draft") == ["label:bug"])
        #expect(terms(item(labels: ["bug"], draft: true), "label:bug -is:draft") == [])
    }

    @Test("of a comma list only the value that matched")
    func commaValues() {
        #expect(terms(item(labels: ["p1"]), "label:p0,p1") == ["label:p1"])
    }

    @Test("free text is quoted when it has a space")
    func freeText() {
        var item = item()
        item.title = "Retry payment capture"
        #expect(terms(item, "retry \"payment capture\"") == ["retry", "\"payment capture\""])
    }

    @Test("a query the item does not match, an empty or an unreadable one gives no terms")
    func noTerms() {
        let item = item()
        #expect(terms(item, "label:bug") == [])
        #expect(terms(item, "") == [])
        #expect(terms(item, "foo:bar") == [])
    }

    @Test("facts about the item come after the query, whatever the query says")
    func facts() {
        let mine = item(author: "prokop", requested: ["Prokop"], assignees: ["prokop"], review: .changesRequested, ci: .failure, merge: .conflict)
        let reasons = FilterEngine.explain(mine, query: "is:pr", me: S.me)

        #expect(reasons == [
            .queryTerm("is:pr"), .reviewRequestedFromMe, .assignedToMe, .changesRequestedOnMyPullRequest, .failingChecks, .mergeConflict,
        ])
    }

    @Test("changes requested on someone else's pull request is not a fact about me")
    func othersChangesRequested() {
        let reasons = FilterEngine.explain(item(review: .changesRequested), query: nil, me: S.me)
        #expect(reasons.isEmpty)
    }

    @Test("an issue assigned to me")
    func issue() {
        #expect(FilterEngine.explain(S.issue(assignees: ["prokop"]), query: "is:issue", me: S.me) == [.queryTerm("is:issue"), .assignedToMe])
    }
}
