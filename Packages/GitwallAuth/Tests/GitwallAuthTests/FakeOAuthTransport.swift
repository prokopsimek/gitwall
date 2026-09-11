import Foundation
import GitwallAuth
import os

/// Records every request and answers from per-path queues, so a test can script a whole exchange.
final class FakeOAuthTransport: OAuthTransport {
    struct Response: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private struct State {
        var queues: [String: [Response]] = [:]
        var requests: [URLRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func enqueue(_ path: String, _ response: Response) {
        state.withLock { $0.queues[path, default: []].append(response) }
    }

    func enqueue(_ path: String, status: Int = 200, json: String) {
        enqueue(path, Response(status: status, body: json, headers: ["Content-Type": "application/json"]))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let response: Response? = state.withLock { state in
            state.requests.append(request)
            guard var queue = state.queues[path], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            state.queues[path] = queue
            return next
        }
        guard let response else { throw RefreshError.network("no scripted response for \(path)") }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (Data(response.body.utf8), http)
    }
}

extension URLRequest {
    /// Decodes an `application/x-www-form-urlencoded` body into a dictionary.
    var formFields: [String: String] {
        guard let body = httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }
}
