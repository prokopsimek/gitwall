import Foundation
import Testing
@testable import GitwallCore

@Suite("SearchQuery")
struct SearchQueryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let me = UserRef(login: "prokopsimek")

    private func item(
        kind: ItemKind = .issue,
        repo: String = "acme/app",
        number: Int = 7,
        title: String = "Change the thing",
        author: String = "someone",
        isDraft: Bool = false,
        labels: [String] = [],
        assignees: [String] = [],
        reviewers: [String] = [],
        requestedReviewers: [String] = [],
        milestone: String? = nil
    ) -> WorkItem {
        WorkItem(
            accountID: UUID(),
            kind: kind,
            repoFullName: repo,
            number: number,
            title: title,
            url: URL(string: "https://example.com/\(number)")!,
            author: UserRef(login: author),
            createdAt: now,
            updatedAt: now,
            isDraft: isDraft,
            labels: labels.map { Label(name: $0) },
            assignees: assignees.map { UserRef(login: $0) },
            milestone: milestone,
            reviewers: reviewers.map { UserRef(login: $0) },
            requestedReviewers: requestedReviewers.map { UserRef(login: $0) }
        )
    }

    private func parse(_ raw: String) throws -> SearchQuery {
        try SearchQuery.parse(raw).get()
    }

    private func error(_ raw: String) -> SearchQueryError? {
        if case .failure(let error) = SearchQuery.parse(raw) { return error }
        return nil
    }

    // MARK: - Parsing

    @Test("an empty query restricts nothing")
    func empty() throws {
        #expect(try parse("").isEmpty)
        #expect(try parse("   \n ").isEmpty)
        #expect(try parse("").matches(item(), me: me))
    }

    @Test("an unknown qualifier is rejected and names itself")
    func unknownQualifier() {
        guard case .unknownQualifier(let name)? = error("assignees:prokopsimek") else {
            Issue.record("expected an unknownQualifier error")
            return
        }
        #expect(name == "assignees")
    }

    @Test("an unclosed quote is rejected")
    func unclosedQuote() {
        #expect(error(#"milestone:"Q4 2026"#) == .unclosedQuote)
    }

    @Test("a qualifier without a value is rejected")
    func emptyValue() {
        guard case .emptyValue(let name)? = error("label:") else {
            Issue.record("expected an emptyValue error")
            return
        }
        #expect(name == "label")
    }

    // MARK: - Combination rules

    @Test("repeated qualifiers combine with AND")
    func repeatedQualifiersAreAnd() throws {
        let query = try parse("assignee:prokopsimek assignee:franta-dxh")
        #expect(query.matches(item(assignees: ["prokopsimek", "franta-dxh"]), me: me))
        #expect(!query.matches(item(assignees: ["prokopsimek"]), me: me))
        #expect(!query.matches(item(assignees: ["franta-dxh"]), me: me))
    }

    @Test("comma separated values inside one qualifier combine with OR")
    func commaIsOr() throws {
        let query = try parse("label:bug,security")
        #expect(query.matches(item(labels: ["bug"]), me: me))
        #expect(query.matches(item(labels: ["security"]), me: me))
        #expect(!query.matches(item(labels: ["chore"]), me: me))
    }

    @Test("the agent queue: me AND one of three agents")
    func meAndAnyAgent() throws {
        let query = try parse("assignee:prokopsimek assignee:franta-dxh,lumir-sokol,tom-gilsky")
        #expect(query.matches(item(assignees: ["prokopsimek", "lumir-sokol"]), me: me))
        #expect(query.matches(item(assignees: ["tom-gilsky", "prokopsimek"]), me: me))
        #expect(!query.matches(item(assignees: ["prokopsimek"]), me: me))
        #expect(!query.matches(item(assignees: ["franta-dxh", "lumir-sokol"]), me: me))
    }

    // MARK: - Boolean operators

    @Test("the agent queue with AND, OR and parentheses")
    func meAndAnyAgentWithOperators() throws {
        let query = try parse("assignee:@me AND (assignee:franta-dxh OR assignee:lumir-sokol OR assignee:tom-gilsky)")
        #expect(query.matches(item(assignees: ["prokopsimek", "lumir-sokol"]), me: me))
        #expect(query.matches(item(assignees: ["tom-gilsky", "prokopsimek"]), me: me))
        #expect(!query.matches(item(assignees: ["prokopsimek"]), me: me))
        #expect(!query.matches(item(assignees: ["franta-dxh", "lumir-sokol"]), me: me))
    }

    @Test("OR matches either side")
    func or() throws {
        let query = try parse("label:bug OR author:alice")
        #expect(query.matches(item(labels: ["bug"]), me: me))
        #expect(query.matches(item(author: "alice"), me: me))
        #expect(query.matches(item(author: "alice", labels: ["bug"]), me: me))
        #expect(!query.matches(item(author: "bob", labels: ["chore"]), me: me))
    }

    @Test("an explicit AND means the same as a space")
    func explicitAnd() throws {
        let query = try parse("label:bug AND author:alice")
        #expect(query == (try parse("label:bug author:alice")))
        #expect(query.matches(item(author: "alice", labels: ["bug"]), me: me))
        #expect(!query.matches(item(author: "alice"), me: me))
    }

    @Test("AND binds tighter than OR")
    func precedence() throws {
        let query = try parse("label:a OR label:b label:c")
        #expect(query.matches(item(labels: ["a"]), me: me))
        #expect(query.matches(item(labels: ["b", "c"]), me: me))
        #expect(!query.matches(item(labels: ["b"]), me: me))
        #expect(!query.matches(item(labels: ["c"]), me: me))
    }

    @Test("parentheses override precedence")
    func parentheses() throws {
        let query = try parse("(label:a OR label:b) label:c")
        #expect(query.matches(item(labels: ["a", "c"]), me: me))
        #expect(query.matches(item(labels: ["b", "c"]), me: me))
        #expect(!query.matches(item(labels: ["a"]), me: me))
    }

    @Test("parentheses nest five levels deep, not six")
    func nestingDepth() throws {
        let five = try parse("(((((label:a)))))")
        #expect(five.matches(item(labels: ["a"]), me: me))
        #expect(error("((((((label:a))))))") == .tooDeep)
    }

    @Test("a minus inside a group negates its term")
    func negationInsideGroup() throws {
        let query = try parse("(-label:blocked OR author:alice)")
        #expect(query.matches(item(labels: ["bug"]), me: me))
        #expect(query.matches(item(author: "alice", labels: ["blocked"]), me: me))
        #expect(!query.matches(item(author: "bob", labels: ["blocked"]), me: me))
    }

    @Test("a minus in front of a group is rejected")
    func negatedGroup() {
        #expect(error("-(label:a OR label:b)") == .negatedGroup)
    }

    @Test("lowercase and quoted operators are plain words")
    func operatorsAsWords() throws {
        let subject = item(title: "Rock or roll")
        #expect(try parse("rock or roll").matches(subject, me: me))
        #expect(try !parse("rock or jazz").matches(subject, me: me))
        #expect(try parse(#""OR""#).matches(item(title: "OR gate"), me: me))
        #expect(try !parse(#""OR""#).matches(item(title: "AND gate"), me: me))
    }

    @Test("a parenthesis inside quotes belongs to the value")
    func quotedParenthesis() throws {
        let query = try parse(#"milestone:"Q4 (late)""#)
        #expect(query.matches(item(milestone: "Q4 (late)"), me: me))
    }

    @Test("unbalanced parentheses are rejected")
    func unbalancedParentheses() {
        #expect(error("(label:a") == .unclosedParenthesis)
        #expect(error("label:a)") == .unexpectedClosingParenthesis)
    }

    @Test("an operator without a term on both sides is rejected")
    func missingOperand() {
        #expect(error("OR label:a") == .missingOperand("OR"))
        #expect(error("label:a AND") == .missingOperand("AND"))
        #expect(error("label:a OR OR label:b") == .missingOperand("OR"))
        #expect(error("label:a OR AND label:b") == .missingOperand("OR"))
        #expect(error("(OR label:a)") == .missingOperand("OR"))
    }

    @Test("empty parentheses are rejected")
    func emptyGroup() {
        #expect(error("()") == .emptyGroup)
        #expect(error("label:a ()") == .emptyGroup)
    }

    @Test("a bare @login is text, as on GitHub")
    func bareMentionIsText() throws {
        let query = try parse("@lumir-sokol")
        #expect(query.matches(item(title: "Ping @lumir-sokol"), me: me))
        #expect(!query.matches(item(assignees: ["lumir-sokol"]), me: me))
    }

    @Test("a login value may carry a leading @")
    func atLogin() throws {
        let query = try parse("assignee:@franta-dxh")
        #expect(query.matches(item(assignees: ["franta-dxh"]), me: me))
        #expect(!query.matches(item(assignees: ["prokopsimek"]), me: me))
    }

    @Test("a leading minus negates the whole term")
    func negation() throws {
        let query = try parse("-label:blocked")
        #expect(query.matches(item(labels: ["bug"]), me: me))
        #expect(!query.matches(item(labels: ["blocked"]), me: me))
    }

    @Test("a negated comma list excludes every value")
    func negatedCommaList() throws {
        let query = try parse("-author:renovate,dependabot")
        #expect(query.matches(item(author: "someone"), me: me))
        #expect(!query.matches(item(author: "renovate"), me: me))
        #expect(!query.matches(item(author: "dependabot"), me: me))
    }

    // MARK: - Values

    @Test("quoted values keep their spaces")
    func quotedValue() throws {
        let query = try parse(#"milestone:"Q4 2026""#)
        #expect(query.matches(item(milestone: "Q4 2026"), me: me))
        #expect(!query.matches(item(milestone: "Q4"), me: me))
    }

    @Test("logins and labels are compared case-insensitively")
    func caseInsensitive() throws {
        #expect(try parse("assignee:ProkopSimek").matches(item(assignees: ["prokopsimek"]), me: me))
        #expect(try parse("label:Bug").matches(item(labels: ["bug"]), me: me))
    }

    @Test("a trailing [bot] is ignored, as it is for authors elsewhere")
    func botSuffix() throws {
        #expect(try parse("author:renovate").matches(item(author: "renovate[bot]"), me: me))
        #expect(try parse("author:renovate[bot]").matches(item(author: "renovate"), me: me))
    }

    @Test("@me resolves to the account identity")
    func atMe() throws {
        let query = try parse("assignee:@me")
        #expect(query.matches(item(assignees: ["prokopsimek"]), me: me))
        #expect(!query.matches(item(assignees: ["franta-dxh"]), me: me))
        #expect(!query.matches(item(assignees: ["prokopsimek"]), me: nil))
    }

    // MARK: - Qualifiers

    @Test("people qualifiers read their own field")
    func peopleQualifiers() throws {
        let subject = item(author: "alice", assignees: ["bob"], reviewers: ["carol"], requestedReviewers: ["dave"])
        #expect(try parse("author:alice").matches(subject, me: me))
        #expect(try parse("assignee:bob").matches(subject, me: me))
        #expect(try parse("reviewed-by:carol").matches(subject, me: me))
        #expect(try parse("review-requested:dave").matches(subject, me: me))
        #expect(try !parse("author:bob").matches(subject, me: me))
    }

    @Test("involves matches an author, assignee or reviewer")
    func involves() throws {
        let query = try parse("involves:alice")
        #expect(query.matches(item(author: "alice"), me: me))
        #expect(query.matches(item(assignees: ["alice"]), me: me))
        #expect(query.matches(item(reviewers: ["alice"]), me: me))
        #expect(query.matches(item(requestedReviewers: ["alice"]), me: me))
        #expect(!query.matches(item(author: "bob"), me: me))
    }

    @Test("repo and org read the repository name")
    func repoAndOrg() throws {
        let subject = item(repo: "acme/app")
        #expect(try parse("repo:acme/app").matches(subject, me: me))
        #expect(try parse("org:acme").matches(subject, me: me))
        #expect(try !parse("org:other").matches(subject, me: me))
    }

    @Test("is and type select the kind and drafts")
    func isAndType() throws {
        let pr = item(kind: .pullRequest)
        let draft = item(kind: .pullRequest, isDraft: true)
        let issue = item(kind: .issue)
        #expect(try parse("is:pr").matches(pr, me: me))
        #expect(try !parse("is:pr").matches(issue, me: me))
        #expect(try parse("type:issue").matches(issue, me: me))
        #expect(try parse("is:draft").matches(draft, me: me))
        #expect(try !parse("is:draft").matches(pr, me: me))
        #expect(try parse("is:open").matches(pr, me: me))
    }

    @Test("an unknown value of is: is rejected")
    func unknownIsValue() {
        guard case .unknownValue(let qualifier, let value)? = error("is:merged") else {
            Issue.record("expected an unknownValue error")
            return
        }
        #expect(qualifier == "is")
        #expect(value == "merged")
    }

    // MARK: - Free text

    @Test("bare words match the title, the repository or the number")
    func freeText() throws {
        let subject = item(repo: "acme/app", number: 42, title: "Change the thing")
        #expect(try parse("thing").matches(subject, me: me))
        #expect(try parse("acme/app").matches(subject, me: me))
        #expect(try parse("#42").matches(subject, me: me))
        #expect(try !parse("missing").matches(subject, me: me))
    }

    @Test("a negated bare word excludes it")
    func negatedFreeText() throws {
        let query = try parse("-flaky")
        #expect(query.matches(item(title: "Change the thing"), me: me))
        #expect(try !parse("-flaky").matches(item(title: "Fix the flaky test"), me: me))
    }

    @Test("several bare words all have to match")
    func freeTextIsAnd() throws {
        let subject = item(title: "Change the thing")
        #expect(try parse("change thing").matches(subject, me: me))
        #expect(try !parse("change missing").matches(subject, me: me))
    }
}
