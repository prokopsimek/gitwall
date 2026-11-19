import Foundation
import GitwallGitHub

/// Answers each GraphQL request with whatever `answer` makes of its query and variables, so a test can page through
/// forty answers or split one search into several without queueing every answer up front. Records each request.
/// Never touches the network.
actor ScriptedTransport: HTTPTransport {
    struct Request: Sendable {
        let url: URL?
        let query: String
        let variables: [String: String]
    }

    private let answer: @Sendable (Request) -> StubTransport.Response
    private(set) var requests: [Request] = []

    init(_ answer: @escaping @Sendable (Request) -> StubTransport.Response) {
        self.answer = answer
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let recorded = Request(url: request.url, query: body["query"] as? String ?? "",
                               variables: body["variables"] as? [String: String] ?? [:])
        requests.append(recorded)
        let response = answer(recorded)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: response.headers.merging(["Content-Type": "application/json"]) { current, _ in current }
        )!
        return (response.body, http)
    }
}
