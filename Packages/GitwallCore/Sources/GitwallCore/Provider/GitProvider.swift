import Foundation

public struct RepoRef: Codable, Hashable, Identifiable, Sendable {
    public var id: String { fullName }
    public var fullName: String
    public var description: String?
    public var isPrivate: Bool
    public var isArchived: Bool
    public var updatedAt: Date?

    public init(fullName: String, description: String? = nil, isPrivate: Bool = false, isArchived: Bool = false, updatedAt: Date? = nil) {
        self.fullName = fullName
        self.description = description
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.updatedAt = updatedAt
    }
}

/// An organization (GitHub) or group (GitLab) usable as a dynamic source.
public struct ContainerRef: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var source: RepoSource
    public var avatarURL: URL?

    public init(id: String, name: String, source: RepoSource, avatarURL: URL? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.avatarURL = avatarURL
    }
}

public struct ProviderCapabilities: Hashable, Sendable {
    /// "Pull request" or "Merge request".
    public var pullRequestTerm: String
    public var pullRequestAbbreviation: String
    public var supportsOrganizationSources: Bool
    public var supportsGroupSources: Bool
    /// Whether review requests addressed to a team the user belongs to are recognised.
    public var resolvesTeamReviewRequests: Bool

    public init(
        pullRequestTerm: String,
        pullRequestAbbreviation: String,
        supportsOrganizationSources: Bool,
        supportsGroupSources: Bool,
        resolvesTeamReviewRequests: Bool
    ) {
        self.pullRequestTerm = pullRequestTerm
        self.pullRequestAbbreviation = pullRequestAbbreviation
        self.supportsOrganizationSources = supportsOrganizationSources
        self.supportsGroupSources = supportsGroupSources
        self.resolvesTeamReviewRequests = resolvesTeamReviewRequests
    }
}

public enum ProviderError: Error, Hashable, Sendable, LocalizedError {
    case unauthorized
    case rateLimited(resetAt: Date?)
    case network(String)
    case server(status: Int, message: String)
    case invalidResponse(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The token was rejected. Check that it is valid and has the required scopes."
        case .rateLimited(let resetAt):
            if let resetAt {
                "API rate limit reached. Resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
            } else {
                "API rate limit reached."
            }
        case .network(let message): "Network error: \(message)"
        case .server(let status, let message): "Server error \(status): \(message)"
        case .invalidResponse(let message): "Unexpected response: \(message)"
        case .notFound(let what): "Not found: \(what)"
        }
    }
}

/// One implementation per hosting platform. Must not depend on anything outside GitwallCore.
public protocol GitProvider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }

    /// Validates the token and returns the identity it belongs to.
    func verify(baseURL: URL, token: String) async throws -> UserRef

    /// Repositories the token can see, optionally narrowed by a search string.
    func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef]

    /// Organizations / groups the token can see.
    func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef]

    /// All open items of the requested kinds for the account's sources.
    func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem]
}
