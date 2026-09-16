import Foundation

/// Why a query string could not be read, phrased so the preset editor can show it as it is.
public enum SearchQueryError: Error, Equatable, Hashable, Sendable {
    case unknownQualifier(String)
    case unknownValue(qualifier: String, value: String)
    case emptyValue(String)
    case unclosedQuote
    case unclosedParenthesis
    case unexpectedClosingParenthesis
    /// `AND` or `OR` with nothing on one side.
    case missingOperand(String)
    case emptyGroup
    case tooDeep
    case negatedGroup
    /// `@login` without a qualifier. GitHub answers it with a validation error, or with nothing inside `OR`.
    case bareMention(String)

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
        case .unclosedParenthesis:
            "A parenthesis is never closed."
        case .unexpectedClosingParenthesis:
            "“)” has no matching “(”."
        case .missingOperand(let keyword):
            "“\(keyword)” needs a term on both sides."
        case .emptyGroup:
            "The parentheses are empty."
        case .tooDeep:
            "Parentheses nest at most \(SearchQuery.maxDepth) levels deep, as on GitHub."
        case .negatedGroup:
            "A leading minus excludes one term. Put it on each term inside the parentheses instead."
        case .bareMention(let mention):
            "“\(mention)” needs a qualifier, for example assignee:\(mention.dropFirst()). Quote it to search the text."
        }
    }
}

/// A preset query written in GitHub's search syntax and evaluated locally against the snapshot, so the
/// menu bar, the window and the widget all agree and both providers behave the same. See
/// `docs/adr/0008-preset-queries-use-github-search-syntax-locally.md` and
/// `docs/adr/0009-preset-queries-accept-and-or-and-parentheses.md`.
///
/// A space or `AND` combines terms with AND, `OR` with OR, and AND binds tighter; parentheses group, up to five
/// levels deep. A leading `-` negates one term. There is no `NOT` keyword, and a minus in front of a group or a bare
/// `@login` is an error, as it is on GitHub. Comma separated values inside one term are OR here; GitHub only honours
/// that for `label:` and ignores it for `assignee:`, so the comma form does not paste into GitHub.
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

    indirect enum Expression: Equatable, Sendable {
        case term(Term)
        case all([Expression])
        case any([Expression])
    }

    /// Nil for an empty query.
    var root: Expression?

    public var isEmpty: Bool { root == nil }

    public static let supportedQualifiers = Qualifier.allCases.map(\.rawValue).sorted()
    public static let supportedIsValues = State.allCases.map(\.rawValue).sorted()
    /// GitHub's limit for nested parentheses.
    static let maxDepth = 5

    // MARK: - Parsing

    public static func parse(_ raw: String) -> Result<SearchQuery, SearchQueryError> {
        switch tokenize(raw) {
        case .failure(let error):
            return .failure(error)
        case .success(let tokens):
            if tokens.isEmpty { return .success(SearchQuery(root: nil)) }
            var parser = Parser(tokens: tokens)
            return parser.parseQuery().map { SearchQuery(root: $0) }
        }
    }

    enum Token: Equatable {
        /// `quoted` keeps `"OR"` a word rather than an operator.
        case word(String, quoted: Bool)
        case open
        case close
    }

    /// Splits on whitespace and around parentheses, except inside double quotes. Quotes are dropped; everything
    /// else, including the leading `-` and the `:`, is left for ``term(from:)``.
    private static func tokenize(_ raw: String) -> Result<[Token], SearchQueryError> {
        var tokens: [Token] = []
        var current = ""
        var quoted = false
        var inQuotes = false

        func flush() {
            if !current.isEmpty { tokens.append(.word(current, quoted: quoted)) }
            current = ""
            quoted = false
        }

        for character in raw {
            if character == "\"" {
                inQuotes.toggle()
                quoted = true
            } else if inQuotes {
                current.append(character)
            } else if character.isWhitespace {
                flush()
            } else if character == "(" {
                if current == "-", !quoted { return .failure(.negatedGroup) }
                flush()
                tokens.append(.open)
            } else if character == ")" {
                flush()
                tokens.append(.close)
            } else {
                current.append(character)
            }
        }
        if inQuotes { return .failure(.unclosedQuote) }
        flush()
        return .success(tokens)
    }

    /// Recursive descent over the tokens: `or := and ("OR" and)*`, `and := unary ("AND"? unary)*`,
    /// `unary := "(" or ")" | word`. AND binds tighter than OR, as in GitHub's own grammar.
    private struct Parser {
        let tokens: [Token]
        var position = 0
        var depth = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        private var current: Token? { position < tokens.count ? tokens[position] : nil }

        private func isKeyword(_ token: Token?, _ keyword: String) -> Bool {
            if case .word(let text, quoted: false)? = token { return text == keyword }
            return false
        }

        private func isOperator(_ token: Token?) -> Bool {
            isKeyword(token, "AND") || isKeyword(token, "OR")
        }

        mutating func parseQuery() -> Result<Expression, SearchQueryError> {
            let result = parseOr()
            guard case .success = result else { return result }
            if current == .close { return .failure(.unexpectedClosingParenthesis) }
            return result
        }

        private mutating func parseOr() -> Result<Expression, SearchQueryError> {
            var operands: [Expression] = []
            switch parseAnd(after: nil) {
            case .success(let expression): operands.append(expression)
            case .failure(let error): return .failure(error)
            }
            while isKeyword(current, "OR") {
                position += 1
                switch parseAnd(after: "OR") {
                case .success(let expression): operands.append(expression)
                case .failure(let error): return .failure(error)
                }
            }
            return .success(operands.count == 1 ? operands[0] : .any(operands))
        }

        /// `pending` is the operator just consumed; it is the one missing an operand when no term follows.
        private mutating func parseAnd(after pending: String?) -> Result<Expression, SearchQueryError> {
            var operands: [Expression] = []
            var pending = pending
            while true {
                guard startsOperand else {
                    if let keyword = pending { return .failure(.missingOperand(keyword)) }
                    if !operands.isEmpty { return .success(operands.count == 1 ? operands[0] : .all(operands)) }
                    if case .word(let keyword, _)? = current { return .failure(.missingOperand(keyword)) }
                    return .failure(current == .close ? .emptyGroup : .unclosedParenthesis)
                }
                switch parseUnary() {
                case .success(let expression): operands.append(expression)
                case .failure(let error): return .failure(error)
                }
                pending = nil
                if isKeyword(current, "AND") {
                    position += 1
                    pending = "AND"
                }
            }
        }

        /// A word or an opening parenthesis; an operator or `)` cannot start an operand.
        private var startsOperand: Bool {
            guard let token = current, token != .close else { return false }
            return !isOperator(token)
        }

        private mutating func parseUnary() -> Result<Expression, SearchQueryError> {
            switch current {
            case .open:
                position += 1
                depth += 1
                guard depth <= maxDepth else { return .failure(.tooDeep) }
                let inner = parseOr()
                guard case .success = inner else { return inner }
                guard current == .close else { return .failure(.unclosedParenthesis) }
                position += 1
                depth -= 1
                return inner
            case .word(let text, let quoted):
                position += 1
                let body = text.hasPrefix("-") ? String(text.dropFirst()) : text
                if !quoted, body.count > 1, body.hasPrefix("@"), !body.contains(":") {
                    return .failure(.bareMention(body))
                }
                return term(from: text).map { .term($0) }
            // Unreachable: `parseAnd` only calls this when `startsOperand` holds.
            case .close, nil:
                return .failure(.unclosedParenthesis)
            }
        }
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
        guard let root else { return true }
        return matches(item, root, me: me)
    }

    private func matches(_ item: WorkItem, _ expression: Expression, me: UserRef?) -> Bool {
        switch expression {
        case .term(let term):
            // Values inside one term are OR; a negated term must match none of them.
            let matched = term.values.contains { matches(item, term: term, value: $0, me: me) }
            return term.isNegated ? !matched : matched
        case .all(let operands):
            return operands.allSatisfy { matches(item, $0, me: me) }
        case .any(let operands):
            return operands.contains { matches(item, $0, me: me) }
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

    /// `@me` stands for the account identity, as it does on GitHub; without an identity it matches nothing. Any
    /// other leading `@` is dropped, since no login can contain one: `assignee:@octocat` reads as `octocat`.
    private func sameLogin(_ login: String, _ value: String, me: UserRef?) -> Bool {
        if value == "@me" {
            guard let me else { return false }
            return LoginMatch.same(login, me.login)
        }
        return LoginMatch.same(login, value.hasPrefix("@") ? String(value.dropFirst()) : value)
    }
}
