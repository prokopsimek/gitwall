import Foundation
import Testing
@testable import GitwallCore

@Suite("How a failed preset search counts")
struct PresetSearchFailureTests {
    @Test("GraphQL errors in a 200 answer and a rejected search belong to the preset, coded by status alone",
          arguments: [200, 400, 422])
    func queryErrors(status: Int) {
        let error = ProviderError.server(status: status, message: "Validation failed: is:pr org:octo-org author:bob")
        #expect(PresetSearchFailure(error) == .query(code: String(status)))
    }

    @Test("every other provider error fails the account",
          arguments: [
              ProviderError.unauthorized,
              .rateLimited(resetAt: nil),
              .network("The network connection was lost."),
              .server(status: 401, message: "Bad credentials"),
              .server(status: 403, message: "Forbidden"),
              .server(status: 404, message: "Not Found"),
              .server(status: 500, message: "Internal Server Error"),
              .server(status: 502, message: "Bad Gateway"),
              .server(status: 503, message: "Service Unavailable"),
              .server(status: 504, message: "Gateway Timeout"),
              .invalidResponse("missing data"),
              .notFound("acme/app"),
              .unsupported("Preset search"),
          ])
    func accountErrors(error: ProviderError) {
        #expect(PresetSearchFailure(error) == .account)
    }

    @Test("an error that does not come from the provider fails the account")
    func foreignError() {
        #expect(PresetSearchFailure(CancellationError()) == .account)
    }
}
