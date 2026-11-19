import Foundation
import GitwallCore

/// Writes a preset's filter as a query for GitHub's `ISSUE_ADVANCED` search, one item kind per query.
///
/// The search only decides what is downloaded; `FilterEngine` still decides what a preset shows. So the query may
/// match more than the preset but never less, because a narrower query would hide items without a trace. Whatever
/// cannot be said to GitHub with at least the same reach is left out and stays with the local filter: drafts, review,
/// CI and merge states, the text field, free text of the query (GitHub matches whole words, Gitwall substrings) and
/// `priority:`. Inside the query, an AND keeps the terms it can translate, an OR is sent only when every branch can be,
/// and a negated term only when its translation is exact.
///
/// Where GitHub's search differs from the local reading, checked on github.com in November 2026:
/// - A GitHub App is `app/<slug>`; GraphQL, and so the snapshot, gives its login as the bare slug, and
///   `reviewed-by:<slug>` finds nothing. Every login is therefore sent in both forms.
/// - `involves:` covers the author and assignees, but neither reviewers, requested reviewers nor app authors.
/// - `is:` and `type:` choose which kind and state of item GitHub searches instead of filtering: `is:issue is:draft`
///   answers with draft pull requests, `-is:open` with closed items. Each query already is one kind and open, so these
///   terms are decided here and never sent, except `is:draft`, which GitHub does filter within pull requests.
/// - Space is AND even between two `org:` qualifiers, and an OR without parentheses takes the whole query apart, so
///   every OR goes out in parentheses.
/// - A negated login GitHub does not know, a typo or a deleted account, empties the whole search: `-author:<unknown>`
///   answers with nothing. Which logins GitHub knows cannot be told from here, so a negated login is only sent as `@me`;
///   every other exclusion of a person or an app, `authorsNone` included, is left to the local filter.
enum PresetSearchQuery {
    /// The filter as top-level AND terms, each a complete piece of GitHub search syntax that can be left out on its own
    /// without making the query narrower. Kind, state, sources and sort are added by ``query(kind:sources:filterTerms:sort:)``.
    ///
    /// Nil when the filter matches nothing of this kind locally (an `is:issue` in a pull request search, an `-is:open`, a
    /// query that cannot be read): no search can be narrower than that, so the kind is not searched at all.
    static func filterTerms(for filter: ItemFilter, kind: ItemKind, now: Date) -> [String]? {
        let node = node(for: filter, kind: kind, now: now)
        if case .never = node { return nil }
        return node.fragments
    }

    static func sortQualifier(for order: GitwallCore.SortOrder) -> String {
        switch order {
        case .lastActivity: "sort:updated-desc"
        case .newestCreated: "sort:created-desc"
        case .oldestCreated: "sort:created-asc"
        // GitHub cannot sort by priority. Any fixed order keeps the pages from shifting while they are read, and the
        // local sort puts what comes back in order.
        case .priority: "sort:updated-desc"
        }
    }

    /// The whole search string. `sources` are the account's qualifiers such as `org:acme` or `repo:acme/app`; several of
    /// them go out as one OR group. Archived repositories are never listed (see `docs/adr/0007`).
    static func query(kind: ItemKind, sources: [String], filterTerms: [String], sort: GitwallCore.SortOrder) -> String {
        var parts = [kind == .pullRequest ? "is:pr" : "is:issue", "is:open"]
        switch sources.count {
        case 0: break
        case 1: parts.append(sources[0])
        default: parts.append("(" + sources.joined(separator: " OR ") + ")")
        }
        parts.append("archived:false")
        parts += filterTerms
        parts.append(sortQualifier(for: sort))
        return parts.joined(separator: " ")
    }

    // MARK: - Preset fields

    private static func node(for filter: ItemFilter, kind: ItemKind, now: Date) -> Node {
        var parts: [Node] = []
        if !filter.relations.isEmpty {
            parts.append(.or(Relation.allCases.filter(filter.relations.contains).map { relation in
                switch relation {
                case .authoredByMe: .term("author:@me")
                case .reviewRequestedFromMe: .term("review-requested:@me")
                case .assignedToMe: .term("assignee:@me")
                }
            }))
        }
        if !filter.labelsAny.isEmpty {
            parts.append(.or(filter.labelsAny.map { quoted("label", $0, negated: false) }))
        }
        parts += filter.labelsNone.map { quoted("label", $0, negated: true) }
        // The author fields compare logins as written, so `@me` there is nobody rather than the account.
        if !filter.authorsAny.isEmpty {
            parts.append(.or(filter.authorsAny.map { login(gitHubLogin($0), "author", negated: false) }))
        }
        parts += filter.authorsNone.map { login(gitHubLogin($0), "author", negated: true) }
        if let days = filter.updatedWithinDays {
            parts.append(updated(withinDays: days, now: now))
        }
        if let milestone = filter.milestone?.trimmingCharacters(in: .whitespaces), !milestone.isEmpty {
            parts.append(quoted("milestone", milestone, negated: false))
        }
        parts.append(node(forQuery: filter.query, kind: kind))
        return .and(parts)
    }

    /// Nothing on GitHub was updated before 2008, so a cutoff before that restricts nothing.
    private static let earliestUpdate = Date(timeIntervalSince1970: 1_199_145_600)

    /// `FilterEngine` keeps an item when `updatedAt` is at or after `now − days × 86 400 s`. GitHub reads a bare date as
    /// the start of that day in a time zone between UTC−12 and UTC+14. The date sent is the day before the cutoff's UTC
    /// date, whose start even at UTC−12 is 12:00 UTC of that earlier day, still before the cutoff. So the search reaches
    /// back at least as far as the preset, and at most about a day and a half further.
    private static func updated(withinDays days: Int, now: Date) -> Node {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        // A cutoff in the future matches nothing locally, so any search is wide enough.
        guard cutoff >= earliestUpdate, cutoff <= now else { return .always }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: cutoff)) else { return .always }
        let date = calendar.dateComponents([.year, .month, .day], from: dayBefore)
        guard let year = date.year, let month = date.month, let day = date.day else { return .always }
        return .term(String(format: "updated:>=%04d-%02d-%02d", year, month, day))
    }

    // MARK: - The query

    private static func node(forQuery raw: String?, kind: ItemKind) -> Node {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .always }
        switch SearchQuery.parse(raw) {
        case .success(let query): return query.root.map { node(for: $0, kind: kind) } ?? .always
        // An unreadable query matches nothing locally, so the kind it is asked of is not searched at all.
        case .failure: return .never
        }
    }

    private static func node(for expression: SearchQuery.Expression, kind: ItemKind) -> Node {
        switch expression {
        case .term(let term): node(for: term, kind: kind)
        case .all(let operands): .and(operands.map { node(for: $0, kind: kind) })
        case .any(let operands): .or(operands.map { node(for: $0, kind: kind) })
        }
    }

    /// The values of one term are OR, and a negated term must match none of them, as in `SearchQuery`.
    private static func node(for term: SearchQuery.Term, kind: ItemKind) -> Node {
        let negated = term.isNegated
        let values: [Node] = term.values.map { value in
            switch term.qualifier {
            // GitHub matches whole words, Gitwall any part of the title, the repository or `#number`.
            case nil, .priority?: .always
            case .author?: login(queryLogin(value), "author", negated: negated)
            case .assignee?: login(queryLogin(value), "assignee", negated: negated)
            // GitHub's reviewed-by sees every review, the snapshot only the latest ones, and its review-requested includes
            // requests to any team of the person; excluding either there could hide what the preset shows.
            case .reviewedBy?: negated ? .always : login(queryLogin(value), "reviewed-by", negated: false)
            case .reviewRequested?: negated ? .always : login(queryLogin(value), "review-requested", negated: false)
            case .involves?: negated ? .always : involves(queryLogin(value))
            case .label?: quoted("label", value, negated: negated)
            case .milestone?: quoted("milestone", value, negated: negated)
            case .repo?: plain("repo", GraphQLQueries.splitFullName(value) == nil ? nil : value, negated: negated)
            case .org?: plain("org", isOwner(value) ? value : nil, negated: negated)
            case .is?, .type?: state(SearchQuery.State(rawValue: value.lowercased()), kind: kind, negated: negated)
            }
        }
        return negated ? .and(values) : .or(values)
    }

    /// Decided here, because GitHub would change the kind or the state of the whole search instead.
    private static func state(_ state: SearchQuery.State?, kind: ItemKind, negated: Bool) -> Node {
        let holds: Bool
        switch state {
        case .pr?, .pullRequest?: holds = kind == .pullRequest
        case .issue?: holds = kind == .issue
        case .open?: holds = true
        case .draft?:
            // An issue is never a draft; within pull requests GitHub filters drafts as Gitwall does.
            guard kind == .pullRequest else { return negated ? .always : .never }
            return .term(negated ? "-is:draft" : "is:draft")
        case nil: return .always
        }
        return holds != negated ? .always : .never
    }

    // MARK: - Values

    /// Whatever GitHub logins are made of. A value with anything else matches no account, so it is never sent.
    private static let loginCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// A login as `LoginMatch` compares it: trimmed and without a trailing `[bot]`. Nil when no account can have it.
    private static func gitHubLogin(_ raw: String) -> String? {
        var login = raw.trimmingCharacters(in: .whitespaces)
        if login.lowercased().hasSuffix("[bot]") { login.removeLast("[bot]".count) }
        guard !login.isEmpty, login.unicodeScalars.allSatisfy(loginCharacters.contains) else { return nil }
        return login
    }

    /// The query reads `@me` as the account and drops any other leading `@`, as `SearchQuery` does.
    private static func queryLogin(_ value: String) -> String? {
        if value == "@me" { return value }
        return gitHubLogin(value.hasPrefix("@") ? String(value.dropFirst()) : value)
    }

    /// A person or an app: `(author:x OR author:app/x)`. An unknown login in that group is simply ignored by GitHub.
    /// Excluded, only `@me` is sent: GitHub answers nothing at all when a negated login is unknown to it, so excluding
    /// anyone else could empty the search, and the local filter excludes them instead.
    private static func login(_ login: String?, _ qualifier: String, negated: Bool) -> Node {
        guard let login else { return .always }
        if login == "@me" { return .term("\(negated ? "-" : "")\(qualifier):@me") }
        guard !negated else { return .always }
        return .or([.term("\(qualifier):\(login)"), .term("\(qualifier):app/\(login)")])
    }

    /// Locally `involves:` is the author, the assignees, the reviewers and the requested reviewers.
    private static func involves(_ login: String?) -> Node {
        guard let login else { return .always }
        guard login != "@me" else {
            return .or(["involves", "reviewed-by", "review-requested"].map { .term("\($0):@me") })
        }
        return .or(["involves", "reviewed-by", "review-requested"].map { self.login(login, $0, negated: false) })
    }

    /// Labels and milestones are names that may hold spaces, so they are always quoted. GitHub has no way to escape a
    /// quote inside one, and padding it would strip, so such a name is left to the local filter.
    private static func quoted(_ qualifier: String, _ value: String, negated: Bool) -> Node {
        guard !value.isEmpty, !value.contains("\""), value == value.trimmingCharacters(in: .whitespaces) else { return .always }
        return .term("\(negated ? "-" : "")\(qualifier):\"\(value)\"")
    }

    private static func plain(_ qualifier: String, _ value: String?, negated: Bool) -> Node {
        guard let value else { return .always }
        return .term("\(negated ? "-" : "")\(qualifier):\(value)")
    }

    /// Owners of repositories, as `GraphQLQueries.splitFullName` accepts them.
    private static let ownerCharacters = loginCharacters.union(CharacterSet(charactersIn: "."))

    static func isOwner(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(ownerCharacters.contains)
    }
}

// MARK: - The query as a tree

/// What is sent for one part of a filter. It always matches at least what the local filter matches there.
private indirect enum Node: Equatable {
    /// No restriction: it holds for every item, or it cannot be said to GitHub without risking a narrower search.
    case always
    /// Holds for no item of the kind searched, such as `is:issue` in a pull request search.
    case never
    case term(String)
    /// AND. At the top level each operand is a fragment of its own.
    case all([Node])
    case any([Node])

    static func and(_ operands: [Node]) -> Node {
        var kept: [Node] = []
        for operand in operands {
            switch operand {
            case .always: continue
            case .never: return .never
            case .all(let inner): kept += inner.filter { !kept.contains($0) }
            default: if !kept.contains(operand) { kept.append(operand) }
            }
        }
        switch kept.count {
        case 0: return .always
        case 1: return kept[0]
        default: return .all(kept)
        }
    }

    static func or(_ operands: [Node]) -> Node {
        var kept: [Node] = []
        for operand in operands {
            switch operand {
            case .always: return .always
            case .never: continue
            case .any(let inner): kept += inner.filter { !kept.contains($0) }
            default: if !kept.contains(operand) { kept.append(operand) }
            }
        }
        switch kept.count {
        case 0: return .never
        case 1: return kept[0]
        default: return .any(kept)
        }
    }

    /// The top-level AND terms. ``PresetSearchQuery/filterTerms(for:kind:now:)`` answers nil for `.never` before it gets here.
    var fragments: [String] {
        switch self {
        case .always, .never: []
        case .all(let operands): operands.map(\.text)
        default: [text]
        }
    }

    private var text: String {
        switch self {
        // Never inside a group: `and` and `or` take them out.
        case .always, .never: ""
        case .term(let text): text
        case .all(let operands): operands.map(\.text).joined(separator: " ")
        case .any(let operands):
            "(" + operands.map { operand in
                if case .all = operand { "(\(operand.text))" } else { operand.text }
            }.joined(separator: " OR ") + ")"
        }
    }
}
