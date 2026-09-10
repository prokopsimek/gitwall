import Foundation
import GitwallGitHub

/// Records every request and answers from a FIFO queue. Never touches the network.
actor StubTransport: HTTPTransport {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(string.utf8), headers: headers)
        }

        static func json(_ data: Data, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, body: data, headers: headers)
        }
    }

    struct QueueExhausted: Error, CustomStringConvertible {
        let request: URLRequest
        var description: String { "StubTransport has no response queued for \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")" }
    }

    private(set) var requests: [URLRequest] = []
    private var queue: [Response] = []

    init(_ responses: [Response] = []) {
        queue = responses
    }

    func enqueue(_ response: Response) {
        queue.append(response)
    }

    func enqueue(_ responses: [Response]) {
        queue.append(contentsOf: responses)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queue.isEmpty else { throw QueueExhausted(request: request) }
        let next = queue.removeFirst()
        var headers = next.headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json; charset=utf-8" }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (next.body, response)
    }

    // MARK: - Inspection helpers

    var requestURLs: [URL] { requests.compactMap(\.url) }

    /// Decoded JSON body of the request at `index` (GraphQL POSTs).
    func body(at index: Int) throws -> [String: Any] {
        let data = try #require(requests[index].httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func graphQLQuery(at index: Int) throws -> String {
        try #require(body(at: index)["query"] as? String)
    }

    func graphQLVariables(at index: Int) throws -> [String: Any] {
        (try body(at: index)["variables"] as? [String: Any]) ?? [:]
    }

    /// String-valued GraphQL variable (Sendable-friendly accessor for tests).
    func graphQLVariable(_ name: String, at index: Int) throws -> String? {
        try graphQLVariables(at: index)[name] as? String
    }
}

import Testing
