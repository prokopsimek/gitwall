import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

private let github = URL(string: "https://github.com")!
private let userURL = URL(string: "https://api.github.com/user")!

/// GitHub now and then answers 502, 503 or 504 for a moment. The client repeats such a request at most twice, after an
/// injected wait, so one bad answer does not make the account look disconnected. Every other failure is final at once.
@Suite("Retrying a GitHub gateway error")
struct RetryTests {
    private let account = Account(kind: .github, baseURL: github, displayName: "GitHub", me: UserRef(login: "octo-tester"),
                                  sources: [.repository(fullName: "octo-org/widgets")])

    /// A gateway error as these tests send it: the status and an empty body, which the client never decodes.
    private static func gatewayError(_ status: Int) -> StubTransport.Response {
        StubTransport.Response(status: status)
    }

    private static func user() throws -> StubTransport.Response {
        .json(try Fixtures.data("rest_user.json"))
    }

    /// The answer for a repository source that has no open pull requests.
    private static let noPullRequests = StubTransport.Response.json(
        #"{"data":{"r0":{"nameWithOwner":"octo-org/widgets","pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#
    )

    private static func repository(_ fullName: String, pushedAt: String) -> String {
        #"{"full_name":"\#(fullName)","description":null,"private":false,"archived":false,"pushed_at":"\#(pushedAt)"}"#
    }

    // MARK: Repeated

    @Test("a REST request answered 502, 503 or 504 succeeds when the repeat gets a good answer", arguments: [502, 503, 504])
    func restRecovers(status: Int) async throws {
        let transport = StubTransport([Self.gatewayError(status), try Self.user()])
        let waits = SleepRecorder()

        _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")

        #expect(await transport.requestURLs == [userURL, userURL])
        #expect(await waits.delays.count == 1)
    }

    @Test("a GraphQL request answered 502, 503 or 504 succeeds when the repeat gets a good answer", arguments: [502, 503, 504])
    func graphQLRecovers(status: Int) async throws {
        let transport = StubTransport([Self.gatewayError(status), Self.noPullRequests])
        let waits = SleepRecorder()

        let items = try await GitHubProvider(transport: transport, sleep: waits.sleep)
            .fetchItems(account: account, token: "t", kinds: [.pullRequest])

        #expect(items.isEmpty)
        #expect(await transport.requests.count == 2)
        let first = try await transport.graphQLQuery(at: 0)
        let repeated = try await transport.graphQLQuery(at: 1)
        #expect(repeated == first)
        #expect(await waits.delays.count == 1)
    }

    @Test("a gateway error on the second page repeats that page, not the first")
    func pageRecovers() async throws {
        let next = "https://api.github.com/user/repos?per_page=100&page=2"
        let transport = StubTransport([
            .json("[\(Self.repository("octo-org/one", pushedAt: "2026-09-10T00:00:00Z"))]", headers: ["Link": "<\(next)>; rel=\"next\""]),
            Self.gatewayError(504),
            .json("[\(Self.repository("octo-org/two", pushedAt: "2026-09-09T00:00:00Z"))]"),
        ])
        let waits = SleepRecorder()

        let repos = try await GitHubProvider(transport: transport, sleep: waits.sleep)
            .discoverRepositories(baseURL: github, token: "t", query: nil)

        #expect(repos.map(\.fullName) == ["octo-org/one", "octo-org/two"])
        let urls = await transport.requestURLs.map(\.absoluteString)
        #expect(urls.count == 3)
        #expect(urls.dropFirst() == [next, next])
        #expect(await waits.delays.count == 1)
    }

    @Test("a gateway error that outlasts two repeats fails as it always did, after three attempts and two waits")
    func outageOutlastsRepeats() async throws {
        let transport = StubTransport([Self.gatewayError(502), Self.gatewayError(502), Self.gatewayError(502), try Self.user()])
        let waits = SleepRecorder()

        await #expect(throws: ProviderError.server(status: 502, message: HTTPURLResponse.localizedString(forStatusCode: 502))) {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")
        }
        #expect(await transport.requests.count == 3)
        #expect(await waits.delays == [.seconds(1), .seconds(2)])
    }

    @Test("a sync cancelled while the client waits sends nothing more")
    func cancelledWhileWaiting() async throws {
        let transport = StubTransport([Self.gatewayError(503), try Self.user()])
        // The sync is cancelled during the wait, and the wait returns as if it had not noticed.
        let provider = GitHubProvider(transport: transport, sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } })

        let sync = Task { try await provider.verify(baseURL: github, token: "t") }

        await #expect(throws: CancellationError.self) { try await sync.value }
        #expect(await transport.requests.count == 1)
    }

    // MARK: Final at once
    //
    // Each failure is followed by a good answer, so a repeat that should not happen would turn the failure into success.

    @Test("401 is unauthorized at once")
    func unauthorizedIsFinal() async throws {
        let transport = StubTransport([.json(try Fixtures.data("rest_error_401.json"), status: 401), try Self.user()])
        let waits = SleepRecorder()

        await #expect(throws: ProviderError.unauthorized) {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")
        }
        #expect(await transport.requests.count == 1)
        #expect(await waits.delays.isEmpty)
    }

    @Test("403 with an exhausted rate limit is rateLimited at once")
    func exhaustedLimitIsFinal() async throws {
        let transport = StubTransport([
            .json(try Fixtures.data("rest_error_403_rate_limit.json"), status: 403,
                  headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1789021534"]),
            try Self.user(),
        ])
        let waits = SleepRecorder()

        await #expect(throws: ProviderError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_789_021_534))) {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")
        }
        #expect(await transport.requests.count == 1)
        #expect(await waits.delays.isEmpty)
    }

    @Test("other 4xx and other server errors fail at once", arguments: [403, 404, 422, 500])
    func otherStatusesAreFinal(status: Int) async throws {
        let transport = StubTransport([.json(#"{"message":"Refused"}"#, status: status), try Self.user()])
        let waits = SleepRecorder()

        await #expect(throws: ProviderError.server(status: status, message: "Refused")) {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")
        }
        #expect(await transport.requests.count == 1)
        #expect(await waits.delays.isEmpty)
    }

    @Test("a GraphQL error answered with 200 fails at once")
    func graphQLErrorIsFinal() async throws {
        let message = "Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug."
        let transport = StubTransport([.json(#"{"data":null,"errors":[{"message":"\#(message)"}]}"#), Self.noPullRequests])
        let waits = SleepRecorder()

        await #expect(throws: ProviderError.server(status: 200, message: message)) {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep)
                .fetchItems(account: account, token: "t", kinds: [.pullRequest])
        }
        #expect(await transport.requests.count == 1)
        #expect(await waits.delays.isEmpty)
    }

    @Test("a network error fails at once")
    func networkErrorIsFinal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        let transport = CountingTransport(URLSessionTransport(session: URLSession(configuration: configuration)))
        let waits = SleepRecorder()

        do {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")
            Issue.record("Expected a network error")
        } catch ProviderError.network {}
        #expect(await transport.count == 1)
        #expect(await waits.delays.isEmpty)
    }

    // MARK: A body that is not JSON
    //
    // GitHub once answered a GraphQL request with 200 after about 12 s and a body that was not JSON. Such an answer is
    // repeated like a gateway error. JSON of an unexpected shape would fail the same way again, so it is final at once.

    /// Bodies that cannot be read as JSON at all: none, an HTML page and a document cut off in the middle.
    private static let notJSON = ["", "<html><body>Unicorn!</body></html>", #"{"data":{"r0":{"nameWith"#]

    @Test("a REST answer of 200 whose body is not JSON succeeds when the repeat gets a good answer", arguments: notJSON)
    func restNotJSONRecovers(body: String) async throws {
        let transport = StubTransport([.json(body), try Self.user()])
        let waits = SleepRecorder()

        _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")

        #expect(await transport.requestURLs == [userURL, userURL])
        #expect(await waits.delays == [.seconds(1)])
    }

    @Test("a GraphQL answer of 200 whose body is not JSON succeeds when the repeat gets a good answer", arguments: notJSON)
    func graphQLNotJSONRecovers(body: String) async throws {
        let transport = StubTransport([.json(body), Self.noPullRequests])
        let waits = SleepRecorder()

        let items = try await GitHubProvider(transport: transport, sleep: waits.sleep)
            .fetchItems(account: account, token: "t", kinds: [.pullRequest])

        #expect(items.isEmpty)
        #expect(await transport.requests.count == 2)
        let first = try await transport.graphQLQuery(at: 0)
        let repeated = try await transport.graphQLQuery(at: 1)
        #expect(repeated == first)
        #expect(await waits.delays == [.seconds(1)])
    }

    @Test("a body that stays not JSON fails as a passing failure after three attempts and two waits")
    func notJSONOutlastsRepeats() async throws {
        let transport = StubTransport(Self.notJSON.map { .json($0) } + [try Self.user()])
        let waits = SleepRecorder()

        do {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")
            Issue.record("Expected the answer that is not JSON to fail the request")
        } catch ProviderError.network(let message) {
            #expect(message == "GitHub sent an answer that could not be read.")
        }
        #expect(await transport.requests.count == 3)
        #expect(await waits.delays == [.seconds(1), .seconds(2)])
    }

    @Test("a sync cancelled while the client waits after a body that is not JSON sends nothing more")
    func cancelledWhileWaitingAfterNotJSON() async throws {
        let transport = StubTransport([.json("<html>"), Self.noPullRequests])
        // The sync is cancelled during the wait, and the wait returns as if it had not noticed.
        let provider = GitHubProvider(transport: transport, sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        let account = account

        let sync = Task { try await provider.fetchItems(account: account, token: "t", kinds: [.pullRequest]) }

        await #expect(throws: CancellationError.self) { try await sync.value }
        #expect(await transport.requests.count == 1)
    }

    @Test("a REST answer of JSON in an unexpected shape fails at once as an unexpected response",
          arguments: [#"{"unexpected":true}"#, "[]", #""text""#, "42", "null"])
    func restWrongShapeIsFinal(body: String) async throws {
        let transport = StubTransport([.json(body), try Self.user()])
        let waits = SleepRecorder()

        do {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep).verify(baseURL: github, token: "t")
            Issue.record("Expected an unexpected response")
        } catch ProviderError.invalidResponse {}
        #expect(await transport.requests.count == 1)
        #expect(await waits.delays.isEmpty)
    }

    @Test("a GraphQL answer of JSON in an unexpected shape fails at once as an unexpected response")
    func graphQLWrongShapeIsFinal() async throws {
        let wrongShape = StubTransport.Response.json(#"{"data":{"r0":{"nameWithOwner":7,"pullRequests":[]}}}"#)
        let transport = StubTransport([wrongShape, Self.noPullRequests])
        let waits = SleepRecorder()

        do {
            _ = try await GitHubProvider(transport: transport, sleep: waits.sleep)
                .fetchItems(account: account, token: "t", kinds: [.pullRequest])
            Issue.record("Expected an unexpected response")
        } catch ProviderError.invalidResponse {}
        #expect(await transport.requests.count == 1)
        #expect(await waits.delays.isEmpty)
    }
}

/// Passes every request on to the real transport and counts them.
private actor CountingTransport: HTTPTransport {
    private let inner: any HTTPTransport
    private(set) var count = 0

    init(_ inner: any HTTPTransport) {
        self.inner = inner
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        return try await inner.send(request)
    }
}
