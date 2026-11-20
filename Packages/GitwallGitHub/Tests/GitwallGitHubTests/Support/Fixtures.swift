import Foundation

enum Fixtures {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "Missing fixture \(name)" }
    }

    static func url(_ name: String) throws -> URL {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = Bundle.module.url(
            forResource: parts[0],
            withExtension: parts.count > 1 ? parts[1] : nil,
            subdirectory: "Fixtures"
        ) else { throw Missing(name: name) }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

/// Answers derived from the captured GraphQL fixtures.
///
/// The three `graphql_preset_search_*` and `graphql_item_states` fixtures were captured on 2026-11-19 from the public
/// repository `prokopsimek/gitwall` with `gh api graphql`, sending the documents of `GraphQLQueries.presetSearch(kind:)`
/// (the search strings `repo:prokopsimek/gitwall archived:false is:issue` and `... is:pr`, no `is:open`, first page) and
/// `GraphQLQueries.itemStates(nodeIDs:)` (two closed issues, two merged pull requests and one id changed at its tail so
/// that it names nothing, in the order the code sends them). That repository has one owner, one organisation-less
/// source and nothing open, so a few shapes cannot be captured from it: an open item, a team review request, an item
/// of a repository outside the account's sources, a draft, a conflict, a failed check, a deleted author. A test that
/// needs one starts from a captured node and changes only the fields that make the difference; the `with` calls in the
/// test say which.
enum Captured {
    /// The owner of the repository the fixtures were captured from, and the repository itself.
    static let owner = "prokopsimek"
    static let repository = "prokopsimek/gitwall"
    /// The id the capture asked for with its tail changed. GitHub answered `NOT_FOUND` at `["nodes", 2]` and a null node.
    static let missingNodeID = "I_kwDOUUWeOM8AAAABQ1mZZZ"

    typealias Object = [String: Any]

    private static func need<T>(_ value: T?) throws -> T {
        guard let value else { throw Fixtures.Missing(name: "a field of a captured fixture") }
        return value
    }

    static func object(_ name: String) throws -> Object {
        try need(JSONSerialization.jsonObject(with: Fixtures.data(name)) as? Object)
    }

    /// The nodes of a captured search page, in GitHub's order.
    static func searchNodes(_ name: String) throws -> [Object] {
        let data = try need(object(name)["data"] as? Object)
        let search = try need(data["search"] as? Object)
        return try need(search["nodes"] as? [Object])
    }

    /// The nodes of the captured item-state answer, in the order of the ids asked for; `NSNull` for the id GitHub could not resolve.
    static func stateNodes() throws -> [Any] {
        let data = try need(object("graphql_item_states.json")["data"] as? Object)
        return try need(data["nodes"] as? [Any])
    }

    /// A captured node with some fields replaced.
    static func with(_ node: Object, _ changes: Object) -> Object {
        node.merging(changes) { _, new in new }
    }

    static func repository(named fullName: String) -> Object { ["nameWithOwner": fullName] }

    /// The `reviewRequests` of a pull request asked for by a team and by one user.
    static func teamReviewRequests(team slug: String, user login: String) -> Object {
        ["nodes": [
            ["requestedReviewer": ["__typename": "Team", "slug": slug, "name": slug.capitalized]],
            ["requestedReviewer": ["__typename": "User", "login": login, "name": login.capitalized,
                                   "avatarUrl": "https://avatars.githubusercontent.com/u/3?v=4"]],
        ]]
    }

    /// A search answer with the envelope of the captured one and the given nodes.
    static func searchAnswer(_ name: String, nodes: [Object], issueCount: Int? = nil) throws -> String {
        var root = try object(name)
        var data = try need(root["data"] as? Object)
        var search = try need(data["search"] as? Object)
        search["nodes"] = nodes
        search["issueCount"] = issueCount ?? nodes.count
        data["search"] = search
        root["data"] = data
        return try json(root)
    }

    /// An item-state answer with the envelope and errors of the captured one and the given nodes.
    static func stateAnswer(nodes: [Any]) throws -> String {
        var root = try object("graphql_item_states.json")
        var data = try need(root["data"] as? Object)
        data["nodes"] = nodes
        root["data"] = data
        return try json(root)
    }

    private static func json(_ object: Object) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
