import Foundation
import GitwallCore

/// A flow that can turn a refresh token into a new credential pair.
public protocol RefreshableFlow: Sendable {
    func refresh(_ token: StoredToken) async throws -> StoredToken
}

/// GitLab Authorization Code flow with PKCE for public clients (gitlab.com and self-managed instances).
/// Access tokens live two hours; refresh tokens rotate on every use.
public struct GitLabPKCEFlow: RefreshableFlow, Sendable {
    public static let defaultRedirectURI = URL(string: "gitwall://oauth/gitlab")!

    private let client: OAuthClient
    private let transport: any OAuthTransport
    private let redirectURI: URL
    private let now: @Sendable () -> Date

    public init(
        client: OAuthClient,
        transport: any OAuthTransport = URLSessionOAuthTransport(),
        redirectURI: URL = GitLabPKCEFlow.defaultRedirectURI,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.transport = transport
        self.redirectURI = redirectURI
        self.now = now
    }

    /// Where to send the user (through `ASWebAuthenticationSession`).
    public func authorizationURL(state: String, challenge: String) -> URL {
        var components = URLComponents(url: client.baseURL.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: client.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// Exchanges the authorization code from the callback for tokens.
    public func exchange(code: String, verifier: String) async throws -> StoredToken {
        try await token(fields: [
            "client_id": client.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": verifier,
        ])
    }

    public func refresh(_ token: StoredToken) async throws -> StoredToken {
        guard let refreshToken = token.refreshToken else { throw RefreshError.invalidGrant }
        return try await self.token(fields: [
            "client_id": client.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "redirect_uri": redirectURI.absoluteString,
        ])
    }

    private func token(fields: [String: String]) async throws -> StoredToken {
        let request = OAuthHTTP.formRequest(url: client.baseURL.appendingPathComponent("oauth/token"), fields: fields)
        let (data, response) = try await transport.send(request)
        let json = OAuthHTTP.json(data)
        switch response.statusCode {
        case 200:
            guard let json, let accessToken = json["access_token"] as? String else {
                throw RefreshError.invalidResponse("token response is missing access_token")
            }
            let issued = now()
            return StoredToken(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                expiresAt: (json["expires_in"] as? Double).map { issued.addingTimeInterval($0) },
                obtainedAt: issued
            )
        case 400, 401:
            // RFC 6749 §5.2: invalid_grant covers revoked, expired and already-rotated refresh tokens.
            if let error = json?["error"] as? String, error == "invalid_grant" || error == "invalid_client" || error == "unauthorized_client" {
                throw RefreshError.invalidGrant
            }
            throw RefreshError.server(status: response.statusCode)
        default:
            throw RefreshError.server(status: response.statusCode)
        }
    }
}
