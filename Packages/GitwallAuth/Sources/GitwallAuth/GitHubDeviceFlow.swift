import Foundation
import GitwallCore

/// What the user has to do: enter `userCode` at `verificationURI`.
public struct DeviceCode: Hashable, Sendable {
    public var userCode: String
    public var verificationURI: URL
    public var deviceCode: String
    /// Minimum seconds between polls, as dictated by GitHub.
    public var interval: TimeInterval
    public var expiresAt: Date

    public init(userCode: String, verificationURI: URL, deviceCode: String, interval: TimeInterval, expiresAt: Date) {
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresAt = expiresAt
    }
}

/// GitHub OAuth device flow (also GitHub Enterprise Server with the user's own OAuth App).
/// Tokens of an OAuth App without token expiration never expire, so there is nothing to refresh.
public struct GitHubDeviceFlow: Sendable {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let client: OAuthClient
    private let transport: any OAuthTransport
    private let sleep: Sleep
    private let now: @Sendable () -> Date

    public init(
        client: OAuthClient,
        transport: any OAuthTransport = URLSessionOAuthTransport(),
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    /// Step 1: ask GitHub for a user code to show, and a device code to poll with.
    public func requestCode() async throws -> DeviceCode {
        let url = client.baseURL.appendingPathComponent("login/device/code")
        let request = OAuthHTTP.formRequest(url: url, fields: ["client_id": client.clientID, "scope": client.scopes.joined(separator: " ")])
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw RefreshError.server(status: response.statusCode) }
        guard let json = OAuthHTTP.json(data),
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)),
              let expiresIn = json["expires_in"] as? Double
        else { throw RefreshError.invalidResponse("device code response is missing fields") }
        let interval = json["interval"] as? Double ?? 5
        return DeviceCode(userCode: userCode, verificationURI: uri, deviceCode: deviceCode, interval: interval, expiresAt: now().addingTimeInterval(expiresIn))
    }

    /// Step 2: poll until the user approves. Respects `interval`, `slow_down` and the code's expiry.
    public func waitForToken(_ code: DeviceCode) async throws -> StoredToken {
        var interval = code.interval
        let url = client.baseURL.appendingPathComponent("login/oauth/access_token")
        while true {
            guard now() < code.expiresAt else { throw DeviceFlowError.expired }
            try await sleep(interval)
            let request = OAuthHTTP.formRequest(url: url, fields: [
                "client_id": client.clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let (data, response) = try await transport.send(request)
            guard let json = OAuthHTTP.json(data) else { throw RefreshError.invalidResponse("poll response is not JSON") }
            if let accessToken = json["access_token"] as? String {
                return StoredToken(accessToken: accessToken, refreshToken: json["refresh_token"] as? String,
                                   expiresAt: (json["expires_in"] as? Double).map { now().addingTimeInterval($0) }, obtainedAt: now())
            }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                // GitHub tells us the new minimum; add the RFC 8628 five seconds if it does not.
                interval = json["interval"] as? Double ?? (interval + 5)
            case "expired_token":
                throw DeviceFlowError.expired
            case "access_denied":
                throw DeviceFlowError.denied
            case let other?:
                throw DeviceFlowError.rejected(code: other)
            case nil:
                guard response.statusCode == 200 else { throw RefreshError.server(status: response.statusCode) }
                throw RefreshError.invalidResponse("poll response has neither a token nor an error")
            }
        }
    }
}
