import Foundation
import Testing
@testable import GitwallGitHub

@Suite("Link header")
struct LinkHeaderTests {
    @Test func parsesNextAndLast() {
        let header = #"<https://api.github.com/user/repos?per_page=2&page=2>; rel="next", <https://api.github.com/user/repos?per_page=2&page=51>; rel="last""#
        #expect(LinkHeader.nextURL(in: header)?.absoluteString == "https://api.github.com/user/repos?per_page=2&page=2")
    }

    @Test func noNextWhenOnlyPrevAndFirst() {
        let header = #"<https://api.github.com/user/repos?page=1>; rel="prev", <https://api.github.com/user/repos?page=1>; rel="first""#
        #expect(LinkHeader.nextURL(in: header) == nil)
    }

    @Test func toleratesMissingSpacesAndUnquotedRel() {
        let header = "<https://ghe.example.com/api/v3/user/repos?page=3>;rel=next,<https://ghe.example.com/api/v3/user/repos?page=9>;rel=last"
        #expect(LinkHeader.nextURL(in: header)?.absoluteString == "https://ghe.example.com/api/v3/user/repos?page=3")
    }

    @Test func nilForEmptyOrGarbage() {
        #expect(LinkHeader.nextURL(in: "") == nil)
        #expect(LinkHeader.nextURL(in: "garbage") == nil)
    }
}
