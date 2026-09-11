import Foundation
import GitwallAuth
import GitwallCore
import Testing

/// Runs the real GitHub device flow against github.com. Skipped unless `GITWALL_OAUTH_INTERACTIVE=1`, because
/// it needs a human to approve the code in a browser:
///
///     GITWALL_OAUTH_INTERACTIVE=1 swift test --package-path Packages/GitwallAuth --filter Interactive
@Suite("Interactive OAuth", .enabled(if: ProcessInfo.processInfo.environment["GITWALL_OAUTH_INTERACTIVE"] == "1"))
struct InteractiveOAuthTests {
    /// Unbuffered progress for a test a human has to watch.
    func note(_ message: String) {
        FileHandle.standardError.write(Data(">>> \(message)\n".utf8))
    }

    @Test("GitHub device flow returns a usable token after the user approves", .timeLimit(.minutes(10)))
    func deviceFlow() async throws {
        let flow = GitHubDeviceFlow(client: OAuthClients.github)
        let code = try await flow.requestCode()
        // stderr, because stdout is block-buffered when the test output is redirected to a file.
        note("Open \(code.verificationURI.absoluteString) and enter: \(code.userCode)")
        let token = try await flow.waitForToken(code)

        #expect(token.accessToken.hasPrefix("gho_"))
        #expect(token.expiresAt == nil, "the OAuth app is configured without token expiration")

        // The token must actually work against the API the app uses.
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let login = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["login"] as? String
        note("Signed in as \(login ?? "?")")
        #expect(login != nil)
    }
}
