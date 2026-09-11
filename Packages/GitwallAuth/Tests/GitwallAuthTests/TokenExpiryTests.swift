import Foundation
import GitwallAuth
import Testing

@Suite("TokenExpiry")
struct TokenExpiryTests {
    /// Builds a UTC date so the expectations do not depend on hand-computed epochs.
    func utc(_ iso: String) -> Date {
        try! Date(iso, strategy: .iso8601)
    }

    @Test("parses GitHub's token expiration header")
    func gitHubHeader() {
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/user")!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["GitHub-Authentication-Token-Expiration": "2026-10-01 12:30:00 UTC"])!
        #expect(TokenExpiry.gitHubExpiration(from: response) == utc("2026-10-01T12:30:00Z"))
    }

    @Test("missing or malformed GitHub header means no expiry")
    func gitHubMissing() {
        let none = HTTPURLResponse(url: URL(string: "https://api.github.com/user")!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        #expect(TokenExpiry.gitHubExpiration(from: none) == nil)
        let bad = HTTPURLResponse(url: URL(string: "https://api.github.com/user")!, statusCode: 200, httpVersion: nil,
                                  headerFields: ["GitHub-Authentication-Token-Expiration": "soon"])!
        #expect(TokenExpiry.gitHubExpiration(from: bad) == nil)
    }

    @Test("parses GitLab's personal access token self response")
    func gitLabSelf() {
        let json = Data(#"{"id":1,"name":"Gitwall token","scopes":["read_api"],"expires_at":"2027-09-10","active":true}"#.utf8)
        #expect(TokenExpiry.gitLabExpiration(fromSelfResponse: json) == utc("2027-09-10T00:00:00Z"))
        let never = Data(#"{"id":1,"expires_at":null}"#.utf8)
        #expect(TokenExpiry.gitLabExpiration(fromSelfResponse: never) == nil)
        #expect(TokenExpiry.gitLabExpiration(fromSelfResponse: Data("not json".utf8)) == nil)
    }
}
