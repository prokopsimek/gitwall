import Foundation
import GitwallAuth
import GitwallCore
import Testing

@Suite("GitHubDeviceFlow")
struct GitHubDeviceFlowTests {
    let client = OAuthClient(kind: .github, baseURL: URL(string: "https://github.com")!, clientID: "Iv1.test", scopes: ["repo", "read:org"])

    /// Records the sleeps the flow asked for instead of waiting.
    final class SleepLog: @unchecked Sendable {
        var intervals: [TimeInterval] = []
        func sleep(_ interval: TimeInterval) async throws { intervals.append(interval) }
    }

    @Test("requests a device code with client id and scopes")
    func requestCode() async throws {
        let transport = FakeOAuthTransport()
        transport.enqueue("/login/device/code", json: #"{"device_code":"dev123","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":899,"interval":5}"#)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let flow = GitHubDeviceFlow(client: client, transport: transport, now: { now })

        let code = try await flow.requestCode()

        #expect(code.userCode == "ABCD-1234")
        #expect(code.verificationURI == URL(string: "https://github.com/login/device"))
        #expect(code.deviceCode == "dev123")
        #expect(code.interval == 5)
        #expect(code.expiresAt == now.addingTimeInterval(899))
        let request = transport.requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.formFields["client_id"] == "Iv1.test")
        #expect(request.formFields["scope"] == "repo read:org")
    }

    @Test("polls until authorized, honouring slow_down")
    func polling() async throws {
        let transport = FakeOAuthTransport()
        transport.enqueue("/login/oauth/access_token", json: #"{"error":"authorization_pending"}"#)
        transport.enqueue("/login/oauth/access_token", json: #"{"error":"slow_down","interval":10}"#)
        transport.enqueue("/login/oauth/access_token", json: #"{"error":"authorization_pending"}"#)
        transport.enqueue("/login/oauth/access_token", json: #"{"access_token":"gho_abc","token_type":"bearer","scope":"repo,read:org"}"#)
        let sleeps = SleepLog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let flow = GitHubDeviceFlow(client: client, transport: transport, sleep: { try await sleeps.sleep($0) }, now: { now })
        let code = DeviceCode(userCode: "ABCD-1234", verificationURI: URL(string: "https://github.com/login/device")!, deviceCode: "dev123", interval: 5, expiresAt: now.addingTimeInterval(900))

        let token = try await flow.waitForToken(code)

        #expect(token.accessToken == "gho_abc")
        #expect(token.refreshToken == nil)
        #expect(token.expiresAt == nil)
        #expect(token.obtainedAt == now)
        // One sleep before each of the four polls; slow_down on the second raises the interval for the rest.
        #expect(sleeps.intervals == [5, 5, 10, 10])
        let poll = transport.requests[0]
        #expect(poll.formFields["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(poll.formFields["device_code"] == "dev123")
        #expect(poll.formFields["client_id"] == "Iv1.test")
    }

    @Test("expired_token and access_denied stop the flow with distinct errors")
    func terminalErrors() async throws {
        for (payload, expected) in [(#"{"error":"expired_token"}"#, DeviceFlowError.expired), (#"{"error":"access_denied"}"#, DeviceFlowError.denied)] {
            let transport = FakeOAuthTransport()
            transport.enqueue("/login/oauth/access_token", json: payload)
            let flow = GitHubDeviceFlow(client: client, transport: transport, sleep: { _ in })
            let code = DeviceCode(userCode: "X", verificationURI: URL(string: "https://github.com/login/device")!, deviceCode: "d", interval: 1, expiresAt: .distantFuture)
            await #expect(throws: expected) { try await flow.waitForToken(code) }
        }
    }

    @Test("gives up when the device code expires locally")
    func localExpiry() async throws {
        let transport = FakeOAuthTransport()
        transport.enqueue("/login/oauth/access_token", json: #"{"error":"authorization_pending"}"#)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let flow = GitHubDeviceFlow(client: client, transport: transport, sleep: { _ in }, now: { now })
        let code = DeviceCode(userCode: "X", verificationURI: URL(string: "https://github.com/login/device")!, deviceCode: "d", interval: 1, expiresAt: now.addingTimeInterval(-1))
        await #expect(throws: DeviceFlowError.expired) { try await flow.waitForToken(code) }
    }

    @Test("uses the account's host for GitHub Enterprise Server")
    func enterpriseHost() async throws {
        let ghes = OAuthClient(kind: .github, baseURL: URL(string: "https://github.example.com")!, clientID: "abc", scopes: ["repo"])
        let transport = FakeOAuthTransport()
        transport.enqueue("/login/device/code", json: #"{"device_code":"d","user_code":"U","verification_uri":"https://github.example.com/login/device","expires_in":900,"interval":5}"#)
        _ = try await GitHubDeviceFlow(client: ghes, transport: transport).requestCode()
        #expect(transport.requests[0].url?.host == "github.example.com")
    }
}
