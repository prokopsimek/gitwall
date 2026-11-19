import Foundation
import GitwallCore
import OSLog

let gitHubLog = Logger(subsystem: "cz.prokopsimek.gitwall", category: "github")

/// Builds authenticated requests, decodes their answers and maps HTTP failures to `ProviderError`.
struct GitHubClient: Sendable {
    let transport: any HTTPTransport
    let userAgent: String
    /// Waits before a request is sent again after a gateway error or a body that is not JSON. Tests inject one that
    /// returns at once.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Requests

    func request(_ url: URL, token: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// GET returning the decoded body and the raw response (for pagination headers).
    func get<T: Decodable>(_ type: T.Type, url: URL, token: String) async throws -> (T, HTTPURLResponse) {
        try await send(request(url, token: token), decoding: type)
    }

    /// Follows `Link: rel="next"` up to `maxPages` pages, concatenating array bodies.
    func getAllPages<T: Decodable>(_ type: T.Type, url: URL, token: String, maxPages: Int) async throws -> [T] {
        var results: [T] = []
        var next: URL? = url
        var page = 0
        while let url = next, page < maxPages {
            page += 1
            let (items, response) = try await get([T].self, url: url, token: token)
            results.append(contentsOf: items)
            next = response.value(forHTTPHeaderField: "Link").flatMap(LinkHeader.nextURL(in:))
        }
        return results
    }

    func graphQL<T: Decodable>(_ type: T.Type, endpoint: URL, token: String, query: String, variables: [String: String?] = [:]) async throws -> GraphQLResponse<T> {
        var payload: [String: Any] = ["query": query]
        let vars = variables.compactMapValues { $0 }
        if !vars.isEmpty { payload["variables"] = vars }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (decoded, _) = try await send(request(endpoint, token: token, method: "POST", body: body),
                                          decoding: GraphQLResponse<T>.self)
        if let rateLimit = decoded.data?.rateLimitInfo {
            gitHubLog.debug("GraphQL cost \(rateLimit.cost) remaining \(rateLimit.remaining)")
        }
        if decoded.data == nil, let errors = decoded.errors, !errors.isEmpty {
            throw Self.map(graphQLErrors: errors)
        }
        return decoded
    }

    // MARK: Errors

    /// The waits before the first and the second repeat of a request that ended in 502, 503 or 504, or in a 2xx answer
    /// whose body is not JSON.
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(2)]

    /// What a request fails with when every attempt got a 2xx answer whose body is not JSON. It is a passing failure
    /// like a lost connection, because the request itself is fine, so the sync's quiet period covers it.
    private static let unreadableAnswer = ProviderError.network("GitHub sent an answer that could not be read.")

    /// Every request goes through here, and its answer is decoded here. A gateway error, or a 2xx answer whose body is
    /// not JSON at all, is repeated after each of `retryDelays`, so a request gets at most three attempts; any other
    /// failure, and the failure of the last attempt, is thrown at once.
    private func send<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> (T, HTTPURLResponse) {
        var delays = Self.retryDelays[...]
        while true {
            let (data, response) = try await transport.send(request)
            let failure: ProviderError
            // What the log says GitHub answered: the status, and the size of a body that is not JSON.
            let answer: String
            if 200..<300 ~= response.statusCode {
                if let value = try Self.decode(type, from: data) { return (value, response) }
                failure = Self.unreadableAnswer
                answer = "\(response.statusCode) with \(data.count) bytes that are not JSON"
            } else {
                failure = Self.map(status: response.statusCode, data: data, response: response)
                guard Self.isGatewayError(failure) else { throw failure }
                answer = "\(response.statusCode)"
            }
            guard let delay = delays.popFirst() else { throw failure }
            gitHubLog.info("GitHub answered \(answer, privacy: .public), trying again in \(delay, privacy: .public)")
            try await sleep(delay)
            try Task.checkCancellation()
        }
    }

    /// Bad gateway, service unavailable and gateway timeout: GitHub is briefly unreachable, the request itself is fine.
    /// Network errors are left to the sync's own handling, and everything else would fail the same way again.
    private static func isGatewayError(_ error: ProviderError) -> Bool {
        guard case .server(let status, _) = error else { return false }
        return [502, 503, 504].contains(status)
    }

    /// `data` as `type`, or nil when it is not JSON at all, such as an empty or cut-off body, which a repeat may fix.
    /// JSON of another shape would come back the same, so it throws `invalidResponse` at once.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T? {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            guard isJSON(data) else { return nil }
            let detail = describe(error)
            gitHubLog.error("Undecodable GitHub response: \(detail, privacy: .public)")
            throw ProviderError.invalidResponse("GitHub returned data in an unexpected format (\(detail)).")
        }
    }

    /// Whether `data` parses as JSON of any shape, a bare value such as `null` or `42` included.
    private static func isJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
    }

    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context): return "type mismatch for \(type) at \(path(context))"
        case .valueNotFound(let type, let context): return "null \(type) at \(path(context))"
        case .dataCorrupted(let context): return "corrupted data at \(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    static func map(status: Int, data: Data, response: HTTPURLResponse) -> ProviderError {
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let resetAt = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)

        switch status {
        case 401:
            return .unauthorized
        case 403 where remaining == 0:
            return .rateLimited(resetAt: resetAt)
        case 429:
            return .rateLimited(resetAt: retryAfter.map { Date().addingTimeInterval($0) } ?? resetAt)
        default:
            return .server(status: status, message: message)
        }
    }

    static func map(graphQLErrors errors: [GraphQLError]) -> ProviderError {
        let types = Set(errors.compactMap { $0.type?.uppercased() })
        if types.contains("RATE_LIMITED") { return .rateLimited(resetAt: nil) }
        if types.contains("FORBIDDEN") || types.contains("INSUFFICIENT_SCOPES") { return .unauthorized }
        return .server(status: 200, message: errors.map(\.message).joined(separator: " "))
    }

    private struct ErrorBody: Decodable {
        let message: String
    }
}

// MARK: - GraphQL envelope

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let type: String?
    let message: String
    let path: [PathElement]?

    /// GraphQL paths mix strings (field names) and integers (list indices).
    enum PathElement: Decodable, Equatable {
        case key(String)
        case index(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .key(string)
            } else {
                self = .index(try container.decode(Int.self))
            }
        }
    }

    var rootAlias: String? {
        if case .key(let key)? = path?.first { return key }
        return nil
    }
}

struct RateLimitInfo: Decodable {
    let cost: Int
    let remaining: Int
    let resetAt: Date?
}

protocol RateLimitCarrying {
    var rateLimitInfo: RateLimitInfo? { get }
}

extension Decodable {
    var rateLimitInfo: RateLimitInfo? { (self as? RateLimitCarrying)?.rateLimitInfo }
}
