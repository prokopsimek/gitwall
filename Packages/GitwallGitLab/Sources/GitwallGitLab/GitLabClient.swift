import Foundation
import GitwallCore
import OSLog

let gitLabLog = Logger(subsystem: "cz.prokopsimek.gitwall", category: "gitlab")

/// Builds authenticated requests and maps HTTP failures to `ProviderError`.
struct GitLabClient: Sendable {
    let transport: any HTTPTransport
    let userAgent: String

    // MARK: Requests

    func request(_ url: URL, token: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        // Personal access tokens work for REST and GraphQL alike with this header.
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func get<T: Decodable>(_ type: T.Type, url: URL, token: String) async throws -> (T, HTTPURLResponse) {
        let (data, response) = try await send(request(url, token: token))
        return (try decode(type, from: data), response)
    }

    /// Follows `Link: rel="next"` (falling back to `X-Next-Page`) up to `maxPages` pages.
    func getAllPages<T: Decodable>(_ type: T.Type, url: URL, token: String, maxPages: Int) async throws -> [T] {
        var results: [T] = []
        var next: URL? = url
        var page = 0
        while let current = next, page < maxPages {
            page += 1
            let (items, response) = try await get([T].self, url: current, token: token)
            results.append(contentsOf: items)
            next = Self.nextPage(after: current, response: response)
        }
        return results
    }

    static func nextPage(after url: URL, response: HTTPURLResponse) -> URL? {
        if let link = response.value(forHTTPHeaderField: "Link"), let next = LinkHeader.nextURL(in: link) {
            return next
        }
        guard let nextPage = response.value(forHTTPHeaderField: "X-Next-Page"), !nextPage.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "page" }
        items.append(URLQueryItem(name: "page", value: nextPage))
        components.queryItems = items
        return components.url
    }

    func graphQL<T: Decodable>(_ type: T.Type, endpoint: URL, token: String, query: String, variables: [String: Any?]) async throws -> GraphQLResponse<T> {
        var payload: [String: Any] = ["query": query]
        let vars = variables.compactMapValues { $0 }
        if !vars.isEmpty { payload["variables"] = vars }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await send(request(endpoint, token: token, method: "POST", body: body))
        let decoded = try decode(GraphQLResponse<T>.self, from: data)
        if decoded.data == nil, let errors = decoded.errors, !errors.isEmpty {
            throw Self.map(graphQLErrors: errors)
        }
        return decoded
    }

    // MARK: Errors

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.send(request)
        guard 200..<300 ~= response.statusCode else {
            throw Self.map(status: response.statusCode, data: data, response: response)
        }
        return (data, response)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try SnapshotCoding.makeDecoder().decode(type, from: data)
        } catch {
            let detail = Self.describe(error)
            gitLabLog.error("Undecodable GitLab response: \(detail, privacy: .public)")
            throw ProviderError.invalidResponse("GitLab returned data in an unexpected format (\(detail)).")
        }
    }

    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch decoding {
        case .keyNotFound(let key, let context): return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context): return "type mismatch for \(type) at \(path(context))"
        case .valueNotFound(let type, let context): return "null \(type) at \(path(context))"
        case .dataCorrupted(let context): return "corrupted data at \(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    static func map(status: Int, data: Data, response: HTTPURLResponse) -> ProviderError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let message = body?.message ?? body?.error ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401, 403:
            // A read-only client hitting 403 means the token lacks the scope or was revoked.
            return .unauthorized
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let reset = response.value(forHTTPHeaderField: "RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            return .rateLimited(resetAt: retryAfter.map { Date().addingTimeInterval($0) } ?? reset)
        default:
            return .server(status: status, message: message)
        }
    }

    static func map(graphQLErrors errors: [GraphQLError]) -> ProviderError {
        .server(status: 200, message: errors.map(\.message).joined(separator: " "))
    }

    private struct ErrorBody: Decodable {
        let message: String?
        let error: String?
    }
}

/// Parses RFC 8288 `Link` headers.
enum LinkHeader {
    static func nextURL(in header: String) -> URL? {
        for part in header.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2, segments[0].hasPrefix("<"), segments[0].hasSuffix(">") else { continue }
            let isNext = segments.dropFirst().contains { segment in
                segment.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: " ", with: "").lowercased() == "rel=next"
            }
            guard isNext else { continue }
            return URL(string: String(segments[0].dropFirst().dropLast()))
        }
        return nil
    }
}

// MARK: - GraphQL envelope

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
}
