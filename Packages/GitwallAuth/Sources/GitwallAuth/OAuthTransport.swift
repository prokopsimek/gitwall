import Foundation
import GitwallCore

/// Minimal HTTP abstraction for the OAuth flows so tests can run them without a network.
/// Mirrors the provider packages' `HTTPTransport`, but lives here because GitwallAuth depends only on GitwallCore.
public protocol OAuthTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by `URLSession`. Transport-level failures surface as `RefreshError.network`.
public struct URLSessionOAuthTransport: OAuthTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw RefreshError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.network("Expected an HTTP response from \(request.url?.absoluteString ?? "<no URL>")")
        }
        return (data, http)
    }
}
