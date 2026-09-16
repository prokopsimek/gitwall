import Foundation

/// Why a query string could not be read, phrased so the preset editor can show it as it is.
public enum SearchQueryError: Error, Equatable, Hashable, Sendable {
    case unknownQualifier(String)
    case unknownValue(qualifier: String, value: String)
    case emptyValue(String)
    case unclosedQuote

    /// English, user-facing; the preset editor prints this under the field.
    public var message: String {
        switch self {
        case .unknownQualifier(let name):
            "Unknown qualifier “\(name)”. Supported: \(SearchQuery.supportedQualifiers.joined(separator: ", "))."
        case .unknownValue(let qualifier, let value):
            "“\(qualifier):\(value)” is not something Gitwall can check. Try \(SearchQuery.supportedIsValues.joined(separator: ", "))."
        case .emptyValue(let name):
            "“\(name):” has no value."
        case .unclosedQuote:
            "A quote is never closed."
        }
    }
}

/// A preset query written in GitHub's search syntax and evaluated locally against the snapshot, so the
/// menu bar, the window and the widget all agree and both providers behave the same. See
/// `docs/adr/0008-preset-queries-are-evaluated-locally.md`.
///
/// Terms combine with AND, comma separated values inside one term with OR, and a leading `-` negates the
/// whole term — the three rules GitHub documents. There are deliberately no `AND`/`OR`/`NOT` keywords and
/// no parentheses, because GitHub does not document them either.
public struct SearchQuery: Equatable, Sendable {
    /// Named after GitHub's own qualifiers; only the ones the snapshot can answer are here.
    enum Qualifier: String, CaseIterable, Sendable {
        case assignee
        case author
        case label
        case milestone
        case reviewedBy = "reviewed-by"
        case reviewRequested = "review-requested"
        case involves
        case repo
        case org
        case `is`
        case type
    }

    /// The `is:` and `type:` values the snapshot can answer. Gitwall only ever fetches open items, so
    /// `is:open` is always true and `is:closed` would be a lie — it is rejected instead.
    enum State: String, CaseIterable, Sendable {
        case pr
        case pullRequest = "pull-request"
        case issue
        case draft
        case open
    }

    struct Term: Equatable, Sendable {
        var qualifier: Qualifier?
        /// Free text when `qualifier` is nil, otherwise the comma separated values of that qualifier.
        var values: [String]
        var isNegated: Bool
    }

    var terms: [Term]

    public var isEmpty: Bool { terms.isEmpty }

    public static let supportedQualifiers = Qualifier.allCases.map(\.rawValue).sorted()
    public static let supportedIsValues = State.allCases.map(\.rawValue).sorted()

    // MARK: - Parsing

    public static func parse(_ raw: String) -> Result<SearchQuery, SearchQueryError> {
        let tokens: [String]
        switch tokenize(raw) {
        case .success(let value): tokens = value
        case .failure(let error): return .failure(error)
        }

        var terms: [Term] = []
        for token in tokens {
            switch term(from: token) {
            case .success(let term): terms.append(term)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(SearchQuery(terms: terms))
    }

    /// Splits on whitespace, except inside double quotes. Quotes are dropped; everything else, including the
    /// leading `-` and the `:`, is left for ``term(from:)``.
    private static func tokenize(_ raw: String) -> Result<[String], SearchQueryError> {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in raw {
            if character == "\"" {
                inQuotes.toggle()
            } else if character.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if inQuotes { return .failure(.unclosedQuote) }
        if !current.isEmpty { tokens.append(current) }
        return .success(tokens)
    }

    private static func term(from token: String) -> Result<Term, SearchQueryError> {
        var body = token
        var isNegated = false
        if body.hasPrefix("-"), body.count > 1 {
            isNegated = true
            body.removeFirst()
        }

        // `repo:acme/app` and a bare `#42` both contain characters that are not separators, so split once only.
        guard let colon = body.firstIndex(of: ":") else {
            return .success(Term(qualifier: nil, values: [body], isNegated: isNegated))
        }
        let name = String(body[body.startIndex..<colon]).lowercased()
        guard let qualifier = Qualifier(rawValue: name) else {
            return .failure(.unknownQualifier(name))
        }
        let rest = String(body[body.index(after: colon)...])
        let values = rest.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return .failure(.emptyValue(name)) }

        if qualifier == .is || qualifier == .type {
            for value in values where State(rawValue: value.lowercased()) == nil {
                return .failure(.unknownValue(qualifier: name, value: value))
            }
        }
        return .success(Term(qualifier: qualifier, values: values, isNegated: isNegated))
    }

    // MARK: - Matching

    func matches(_ item: WorkItem, me: UserRef?) -> Bool {
        terms.allSatisfy { term in
            // Values inside one term are OR; a negated term must match none of them.
            let matched = term.values.contains { matches(item, term: term, value: $0, me: me) }
            return term.isNegated ? !matched : matched
        }
    }

    private func matches(_ item: WorkItem, term: Term, value: String, me: UserRef?) -> Bool {
        guard let qualifier = term.qualifier else { return matchesText(item, value) }
        switch qualifier {
        case .assignee:
            return item.assignees.contains { sameLogin($0.login, value, me: me) }
        case .author:
            return sameLogin(item.author.login, value, me: me)
        case .label:
            return item.labels.contains { $0.name.caseInsensitiveCompare(value) == .orderedSame }
        case .milestone:
            return item.milestone?.caseInsensitiveCompare(value) == .orderedSame
        case .reviewedBy:
            return item.reviewers.contains { sameLogin($0.login, value, me: me) }
        case .reviewRequested:
            return item.requestedReviewers.contains { sameLogin($0.login, value, me: me) }
        case .involves:
            let everyone = [item.author] + item.assignees + item.reviewers + item.requestedReviewers
            return everyone.contains { sameLogin($0.login, value, me: me) }
        case .repo:
            return item.repoFullName.caseInsensitiveCompare(value) == .orderedSame
        case .org:
            let owner = item.repoFullName.split(separator: "/").first.map(String.init) ?? item.repoFullName
            return owner.caseInsensitiveCompare(value) == .orderedSame
        case .is, .type:
            return matchesState(item, State(rawValue: value.lowercased()))
        }
    }

    private func matchesState(_ item: WorkItem, _ state: State?) -> Bool {
        switch state {
        case .pr, .pullRequest: item.kind == .pullRequest
        case .issue: item.kind == .issue
        case .draft: item.isDraft
        // Gitwall only ever holds open items, so this is true by construction.
        case .open: true
        case nil: false
        }
    }

    /// Same haystacks as the plain "Title, repository or #number contains" field, so the two agree.
    private func matchesText(_ item: WorkItem, _ value: String) -> Bool {
        let needle = value.lowercased()
        guard !needle.isEmpty else { return true }
        return [item.title.lowercased(), item.repoFullName.lowercased(), "#\(item.number)"]
            .contains { $0.contains(needle) }
    }

    /// `@me` stands for the account identity, as it does on GitHub; without an identity it matches nothing.
    private func sameLogin(_ login: String, _ value: String, me: UserRef?) -> Bool {
        if value == "@me" {
            guard let me else { return false }
            return LoginMatch.same(login, me.login)
        }
        return LoginMatch.same(login, value)
    }
}
