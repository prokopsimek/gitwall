import Foundation
import GitwallAuth
import GitwallCore
import Testing

@Suite("GitLabPKCEFlow")
struct GitLabPKCEFlowTests {
    let client = OAuthClient(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, clientID: "app123", scopes: ["read_api", "read_user"])
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("authorization URL carries PKCE, state, scopes and the custom-scheme redirect")
    func authorizationURL() {
        let flow = GitLabPKCEFlow(client: client, transport: FakeOAuthTransport())
        let url = flow.authorizationURL(state: "st4te", challenge: "ch4llenge")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(components.host == "gitlab.com")
        #expect(components.path == "/oauth/authorize")
        #expect(query["client_id"] == "app123")
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "gitwall://oauth/gitlab")
        #expect(query["state"] == "st4te")
        #expect(query["scope"] == "read_api read_user")
        #expect(query["code_challenge"] == "ch4llenge")
        #expect(query["code_challenge_method"] == "S256")
    }

    @Test("exchanges the code with the verifier and maps expiry")
    func exchange() async throws {
        let transport = FakeOAuthTransport()
        transport.enqueue("/oauth/token", json: #"{"access_token":"acc1","token_type":"Bearer","expires_in":7200,"refresh_token":"ref1","created_at":1800000000}"#)
        let flow = GitLabPKCEFlow(client: client, transport: transport, now: { now })

        let token = try await flow.exchange(code: "c0de", verifier: "v3rifier")

        #expect(token.accessToken == "acc1")
        #expect(token.refreshToken == "ref1")
        #expect(token.expiresAt == now.addingTimeInterval(7200))
        #expect(token.obtainedAt == now)
        let fields = transport.requests[0].formFields
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "c0de")
        #expect(fields["code_verifier"] == "v3rifier")
        #expect(fields["client_id"] == "app123")
        #expect(fields["redirect_uri"] == "gitwall://oauth/gitlab")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("refresh rotates both tokens")
    func refresh() async throws {
        let transport = FakeOAuthTransport()
        transport.enqueue("/oauth/token", json: #"{"access_token":"acc2","token_type":"Bearer","expires_in":7200,"refresh_token":"ref2","created_at":1800000000}"#)
        let flow = GitLabPKCEFlow(client: client, transport: transport, now: { now })
        let old = StoredToken(accessToken: "acc1", refreshToken: "ref1", expiresAt: now, obtainedAt: now.addingTimeInterval(-7200))

        let new = try await flow.refresh(old)

        #expect(new.accessToken == "acc2")
        #expect(new.refreshToken == "ref2")
        #expect(new.expiresAt == now.addingTimeInterval(7200))
        let fields = transport.requests[0].formFields
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["refresh_token"] == "ref1")
        #expect(fields["client_id"] == "app123")
    }

    @Test("invalid_grant, server errors and network failures map to RefreshError")
    func errors() async throws {
        let transport = FakeOAuthTransport()
        transport.enqueue("/oauth/token", status: 400, json: #"{"error":"invalid_grant","error_description":"revoked"}"#)
        transport.enqueue("/oauth/token", status: 503, json: "upstream down")
        let flow = GitLabPKCEFlow(client: client, transport: transport, now: { now })
        let old = StoredToken(accessToken: "a", refreshToken: "r", expiresAt: now, obtainedAt: now)

        await #expect(throws: RefreshError.invalidGrant) { try await flow.refresh(old) }
        await #expect(throws: RefreshError.server(status: 503)) { try await flow.refresh(old) }
        // No scripted response left: the fake transport fails like a dropped connection.
        await #expect(throws: RefreshError.self) { try await flow.refresh(old) }
    }

    @Test("a token without a refresh token cannot be refreshed")
    func noRefreshToken() async throws {
        let flow = GitLabPKCEFlow(client: client, transport: FakeOAuthTransport(), now: { now })
        await #expect(throws: RefreshError.invalidGrant) {
            try await flow.refresh(StoredToken(accessToken: "a", obtainedAt: now))
        }
    }
}
