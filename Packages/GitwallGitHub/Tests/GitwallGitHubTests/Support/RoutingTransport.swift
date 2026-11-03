import Foundation
import GitwallGitHub

/// Answers each GraphQL request by the first route whose marker its query contains, so requests that run in
/// parallel cannot swap answers the way they could with the FIFO ``StubTransport``. Never touches the network.
actor RoutingTransport: HTTPTransport {
    struct Unrouted: Error, CustomStringConvertible {
        let query: String
        var description: String { "RoutingTransport has no route for query: \(query.prefix(120))" }
    }

    private let routes: [(marker: String, response: StubTransport.Response)]
    private(set) var queries: [String] = []
    private(set) var variables: [[String: String]] = []

    init(_ routes: [(String, StubTransport.Response)]) {
        self.routes = routes.map { (marker: $0.0, response: $0.1) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = body["query"] as? String ?? ""
        queries.append(query)
        variables.append(body["variables"] as? [String: String] ?? [:])
        guard let route = routes.first(where: { query.contains($0.marker) }) else { throw Unrouted(query: query) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: route.response.status, httpVersion: "HTTP/1.1",
            headerFields: route.response.headers.merging(["Content-Type": "application/json"]) { current, _ in current }
        )!
        return (route.response.body, response)
    }
}
