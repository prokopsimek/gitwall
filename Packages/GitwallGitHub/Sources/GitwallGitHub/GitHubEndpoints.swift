import Foundation

/// API endpoints derived from an account's web base URL.
///
/// `https://github.com` → `https://api.github.com` and `https://api.github.com/graphql`.
/// Any other host is treated as GitHub Enterprise Server: `<scheme>://<host>[:port]/api/v3` and `/api/graphql`.
public struct GitHubEndpoints: Hashable, Sendable {
    public let rest: URL
    public let graphQL: URL

    private static let cloudHosts: Set<String> = ["github.com", "www.github.com", "api.github.com"]

    public init(baseURL: URL) {
        let host = baseURL.host?.lowercased() ?? ""
        if Self.cloudHosts.contains(host) {
            rest = URL(string: "https://api.github.com")!
            graphQL = URL(string: "https://api.github.com/graphql")!
            return
        }
        var components = URLComponents()
        components.scheme = baseURL.scheme ?? "https"
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = ""
        let root = components.url ?? baseURL
        rest = root.appendingPathComponent("api/v3")
        graphQL = root.appendingPathComponent("api/graphql")
    }
}
