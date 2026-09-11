import AppKit
import AuthenticationServices
import GitwallAuth
import GitwallCore
import Observation
import OSLog

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "oauth")

/// Drives the two sign-in flows for the UI. All the protocol work lives in GitwallAuth; this type only
/// owns the window-bound parts: showing the device code and presenting the web sheet.
@MainActor
@Observable
final class OAuthCoordinator: NSObject {
    /// Set while the user has to type a code on GitHub.
    private(set) var deviceCode: DeviceCode?
    private(set) var isWaiting = false

    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private weak var anchor: NSWindow?

    /// A finished sign-in: the credential to store and how the account authenticates from now on.
    struct Result {
        let token: StoredToken
        let authMethod: AuthMethod
    }

    /// Whether Gitwall can sign in to this host without the user registering an application first.
    static func canSignIn(kind: ProviderKind, baseURL: URL) -> Bool {
        OAuthClients.builtInClient(kind: kind, baseURL: baseURL) != nil
    }

    func cancel() {
        webSession?.cancel()
        webSession = nil
        deviceCode = nil
        isWaiting = false
    }

    /// GitHub device flow: shows a code, then polls until the user approves it in the browser.
    /// `onCode` runs as soon as there is something to show, so the sheet can render before the polling starts.
    func signInWithGitHub(baseURL: URL, clientID: String?) async throws -> Result {
        let client = try resolveClient(kind: .github, baseURL: baseURL, clientID: clientID)
        let flow = GitHubDeviceFlow(client: client)
        isWaiting = true
        defer { isWaiting = false; deviceCode = nil }

        let code = try await flow.requestCode()
        deviceCode = code
        NSWorkspace.shared.open(code.verificationURI)
        let token = try await flow.waitForToken(code)
        log.info("GitHub device flow completed for \(baseURL.host ?? "?", privacy: .public)")
        return Result(token: token, authMethod: .oauth(clientID: client.clientID))
    }

    /// GitLab authorization code flow with PKCE, presented in an `ASWebAuthenticationSession` sheet.
    func signInWithGitLab(baseURL: URL, clientID: String?, anchor: NSWindow?) async throws -> Result {
        let client = try resolveClient(kind: .gitlab, baseURL: baseURL, clientID: clientID)
        let flow = GitLabPKCEFlow(client: client)
        let verifier = PKCE.verifier()
        let state = PKCE.state()
        self.anchor = anchor
        isWaiting = true
        defer { isWaiting = false; webSession = nil }

        let callback = try await presentWebSession(url: flow.authorizationURL(state: state, challenge: PKCE.challenge(for: verifier)))
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw OAuthError.stateMismatch
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw OAuthError.declined(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.missingCode
        }
        let token = try await flow.exchange(code: code, verifier: verifier)
        log.info("GitLab PKCE flow completed for \(baseURL.host ?? "?", privacy: .public)")
        return Result(token: token, authMethod: .oauth(clientID: client.clientID))
    }

    // MARK: - Private

    private func resolveClient(kind: ProviderKind, baseURL: URL, clientID: String?) throws -> OAuthClient {
        if let clientID, !clientID.trimmingCharacters(in: .whitespaces).isEmpty {
            let scopes = kind == .github ? OAuthClients.github.scopes : OAuthClients.gitlab.scopes
            return OAuthClient(kind: kind, baseURL: baseURL, clientID: clientID.trimmingCharacters(in: .whitespaces), scopes: scopes)
        }
        guard let client = OAuthClients.builtInClient(kind: kind, baseURL: baseURL) else {
            throw OAuthError.noClientForHost
        }
        return client
    }

    private func presentWebSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: AppGroup.urlScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.missingCode)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                continuation.resume(throwing: OAuthError.cannotPresent)
            }
        }
    }
}

extension OAuthCoordinator: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    }
}

enum OAuthError: LocalizedError {
    case noClientForHost
    case cancelled
    case stateMismatch
    case missingCode
    case declined(String)
    case cannotPresent

    var errorDescription: String? {
        switch self {
        case .noClientForHost:
            "Gitwall can only sign you in to github.com and gitlab.com. For your own server, use a personal access token or enter the client ID of an application you registered there."
        case .cancelled: "Sign-in was cancelled."
        case .stateMismatch: "The sign-in response did not match the request. Try again."
        case .missingCode: "The sign-in response did not contain an authorization code."
        case .declined(let reason): "The sign-in was declined (\(reason))."
        case .cannotPresent: "The sign-in window could not be opened."
        }
    }
}
