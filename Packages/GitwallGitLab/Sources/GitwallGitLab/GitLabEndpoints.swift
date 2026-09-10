import Foundation

/// API endpoints derived from an account's web base URL. Works the same for gitlab.com and self-managed instances.
public struct GitLabEndpoints: Hashable, Sendable {
    public let baseURL: URL
    public let rest: URL
    public let graphQL: URL

    public init(baseURL: URL) {
        var components = URLComponents()
        components.scheme = baseURL.scheme ?? "https"
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = ""
        let root = components.url ?? baseURL
        self.baseURL = root
        rest = root.appendingPathComponent("api/v4")
        graphQL = root.appendingPathComponent("api/graphql")
    }

    /// GitLab returns avatar URLs either absolute (gravatar) or as instance-relative paths.
    public func resolve(avatar: String?) -> URL? {
        guard let avatar = avatar?.trimmingCharacters(in: .whitespaces), !avatar.isEmpty else { return nil }
        if let url = URL(string: avatar), url.scheme != nil { return url }
        return URL(string: avatar, relativeTo: baseURL)?.absoluteURL
    }
}
