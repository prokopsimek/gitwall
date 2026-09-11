import Foundation
import GitwallCore

/// A registered OAuth application: the host it belongs to and the public client identifier.
/// Gitwall uses public clients only (device flow, PKCE), so there is never a client secret.
public struct OAuthClient: Hashable, Sendable {
    public var kind: ProviderKind
    /// Web base URL of the instance, e.g. `https://github.com` or `https://gitlab.example.com`.
    public var baseURL: URL
    public var clientID: String
    public var scopes: [String]

    public init(kind: ProviderKind, baseURL: URL, clientID: String, scopes: [String]) {
        self.kind = kind
        self.baseURL = baseURL
        self.clientID = clientID
        self.scopes = scopes
    }
}

/// Gitwall's own registrations on github.com and gitlab.com, plus resolution for self-hosted instances.
public enum OAuthClients {
    /// GitHub OAuth App "Gitwall" (Device Flow enabled, tokens do not expire).
    public static let github = OAuthClient(
        kind: .github,
        baseURL: URL(string: "https://github.com")!,
        clientID: gitHubClientID,
        scopes: ["repo", "read:org"]
    )

    /// GitLab.com application "Gitwall" (non-confidential, PKCE, redirect `gitwall://oauth/gitlab`).
    public static let gitlab = OAuthClient(
        kind: .gitlab,
        baseURL: URL(string: "https://gitlab.com")!,
        clientID: gitLabClientID,
        scopes: ["read_api", "read_user"]
    )

    // Filled in from the registrations on github.com and gitlab.com; public identifiers, safe to commit.
    static let gitHubClientID = "Ov23liOmHP0FjjOMqSp5"
    static let gitLabClientID = "fd553c55fc301c41ff936230790df736e34bb701b4e04c5c28d027b6d08b554b"

    /// The client to use for `account`: the built-in one for the cloud hosts, or the user's own client ID for
    /// self-hosted instances. `nil` for personal access token accounts and for self-hosted accounts without a client.
    public static func client(for account: Account) -> OAuthClient? {
        switch account.authMethod {
        case .personalAccessToken:
            return nil
        case .oauth(let clientID):
            let scopes = account.kind == .github ? github.scopes : gitlab.scopes
            return OAuthClient(kind: account.kind, baseURL: account.baseURL, clientID: clientID, scopes: scopes)
        }
    }

    /// The built-in client for a cloud host, when `baseURL` is github.com or gitlab.com.
    public static func builtInClient(kind: ProviderKind, baseURL: URL) -> OAuthClient? {
        let host = baseURL.host?.lowercased()
        switch kind {
        case .github: return host == "github.com" ? github : nil
        case .gitlab: return host == "gitlab.com" ? gitlab : nil
        }
    }
}
