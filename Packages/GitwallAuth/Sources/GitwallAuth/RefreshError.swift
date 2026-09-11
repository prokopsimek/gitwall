import Foundation

/// Failures of a token exchange or refresh, reduced to what the sync engine has to react to.
public enum RefreshError: Error, Hashable, Sendable, LocalizedError {
    /// The refresh token was revoked, rotated away or the grant is otherwise dead: only a new sign-in helps.
    case invalidGrant
    /// The request did not complete; the current token stays and the next sync tries again.
    case network(String)
    /// The authorization server answered with an unexpected status.
    case server(status: Int)
    /// The response could not be understood.
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGrant: "The sign-in is no longer valid. Sign in again."
        case .network(let message): "Network error while refreshing the sign-in: \(message)"
        case .server(let status): "The sign-in server answered with status \(status)."
        case .invalidResponse(let message): "Unexpected response from the sign-in server: \(message)"
        }
    }
}

/// Terminal outcomes of the GitHub device flow.
public enum DeviceFlowError: Error, Hashable, Sendable, LocalizedError {
    /// The user did not approve in time (server `expired_token` or the local deadline passed).
    case expired
    /// The user declined the authorization.
    case denied
    /// GitHub answered with an error the flow cannot recover from (`incorrect_client_credentials`, `device_flow_disabled`, …).
    case rejected(code: String)

    public var errorDescription: String? {
        switch self {
        case .expired: "The code expired before it was approved. Try again."
        case .denied: "The sign-in was declined on GitHub."
        case .rejected(let code): "GitHub rejected the sign-in (\(code))."
        }
    }
}
