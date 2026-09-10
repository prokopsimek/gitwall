import Foundation

/// How the app authenticates against an account.
public enum AuthMethod: Codable, Hashable, Sendable {
    case personalAccessToken
    case oauth(clientID: String)
}

/// Where items for an account come from. Explicit repositories or a dynamic container (org / group).
public enum RepoSource: Codable, Hashable, Sendable {
    case repository(fullName: String)
    /// GitHub organization login; all repositories the token can see in it.
    case organization(login: String)
    /// GitLab group full path; all projects in it.
    case group(fullPath: String, includeSubgroups: Bool)

    public var displayName: String {
        switch self {
        case .repository(let fullName): fullName
        case .organization(let login): "\(login)/*"
        case .group(let fullPath, let includeSubgroups): includeSubgroups ? "\(fullPath)/**" : "\(fullPath)/*"
        }
    }

    public var isDynamic: Bool {
        if case .repository = self { return false }
        return true
    }
}

/// A connection to one GitHub / GitLab instance. Tokens are never stored here; they live in the Keychain keyed by `id`.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ProviderKind
    /// Web base URL of the instance, e.g. `https://github.com` or `https://gitlab.example.com`.
    /// Providers derive their API endpoints from it.
    public var baseURL: URL
    public var displayName: String
    /// Identity of the token owner; needed for "authored by me" style filters.
    public var me: UserRef?
    public var authMethod: AuthMethod
    /// Provider-native query appended to the provider's own search (advanced users).
    public var nativeQuery: String?
    public var sources: [RepoSource]

    public init(
        id: UUID = UUID(),
        kind: ProviderKind,
        baseURL: URL,
        displayName: String,
        me: UserRef? = nil,
        authMethod: AuthMethod = .personalAccessToken,
        nativeQuery: String? = nil,
        sources: [RepoSource] = []
    ) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.displayName = displayName
        self.me = me
        self.authMethod = authMethod
        self.nativeQuery = nativeQuery
        self.sources = sources
    }

    public var isCloudInstance: Bool {
        switch kind {
        case .github: baseURL.host?.lowercased() == "github.com"
        case .gitlab: baseURL.host?.lowercased() == "gitlab.com"
        }
    }

    public static func defaultBaseURL(for kind: ProviderKind) -> URL {
        switch kind {
        case .github: URL(string: "https://github.com")!
        case .gitlab: URL(string: "https://gitlab.com")!
        }
    }
}
