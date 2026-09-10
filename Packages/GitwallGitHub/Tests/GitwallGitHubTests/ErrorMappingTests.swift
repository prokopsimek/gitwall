import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!

@Suite("HTTP error mapping")
struct HTTPErrorMappingTests {
    private func verifyError(_ response: StubTransport.Response) async throws -> ProviderError {
        let transport = StubTransport([response])
        do {
            _ = try await GitHubProvider(transport: transport).verify(baseURL: github, token: "t")
        } catch let error as ProviderError {
            return error
        }
        Issue.record("Expected a ProviderError")
        throw ProviderError.invalidResponse("unreachable")
    }

    @Test("401 → unauthorized")
    func unauthorized() async throws {
        let error = try await verifyError(.json(try Fixtures.data("rest_error_401.json"), status: 401))
        #expect(error == .unauthorized)
    }

    @Test("403 with x-ratelimit-remaining: 0 → rateLimited with reset date")
    func primaryRateLimit() async throws {
        let error = try await verifyError(.json(
            try Fixtures.data("rest_error_403_rate_limit.json"),
            status: 403,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1789021534"]
        ))
        #expect(error == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_789_021_534)))
    }

    @Test("429 with retry-after → rateLimited with a reset roughly retry-after seconds from now")
    func secondaryRateLimit() async throws {
        let before = Date()
        let error = try await verifyError(.json(#"{"message":"You have exceeded a secondary rate limit."}"#, status: 429, headers: ["Retry-After": "60"]))
        guard case .rateLimited(let resetAt) = error else {
            Issue.record("Expected rateLimited, got \(error)")
            return
        }
        let reset = try #require(resetAt)
        #expect(reset.timeIntervalSince(before) >= 59)
        #expect(reset.timeIntervalSince(before) <= 61)
    }

    @Test("429 without any hint → rateLimited(nil)")
    func rateLimitWithoutReset() async throws {
        let error = try await verifyError(.json("{}", status: 429))
        #expect(error == .rateLimited(resetAt: nil))
    }

    @Test("403 without rate-limit headers → server with GitHub's message")
    func forbidden() async throws {
        let error = try await verifyError(.json(#"{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com"}"#, status: 403))
        #expect(error == .server(status: 403, message: "Resource not accessible by personal access token"))
    }

    @Test("404 → server(404)")
    func notFound() async throws {
        let error = try await verifyError(.json(#"{"message":"Not Found"}"#, status: 404))
        #expect(error == .server(status: 404, message: "Not Found"))
    }

    @Test("5xx → server with status text when the body is not JSON")
    func serverError() async throws {
        let error = try await verifyError(.json("<html>bad gateway</html>", status: 502))
        guard case .server(let status, let message) = error else {
            Issue.record("Expected server, got \(error)")
            return
        }
        #expect(status == 502)
        #expect(!message.isEmpty)
    }

    @Test("Undecodable success body → invalidResponse")
    func invalidBody() async throws {
        let error = try await verifyError(.json("not json at all"))
        guard case .invalidResponse = error else {
            Issue.record("Expected invalidResponse, got \(error)")
            return
        }
    }
}

@Suite("URLSessionTransport")
struct URLSessionTransportTests {
    @Test("URLError becomes ProviderError.network")
    func mapsURLError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))

        await #expect(throws: ProviderError.self) {
            _ = try await transport.send(URLRequest(url: URL(string: "https://api.github.com/user")!))
        }
        do {
            _ = try await transport.send(URLRequest(url: URL(string: "https://api.github.com/user")!))
        } catch let error as ProviderError {
            guard case .network = error else {
                Issue.record("Expected network, got \(error)")
                return
            }
        }
    }
}
