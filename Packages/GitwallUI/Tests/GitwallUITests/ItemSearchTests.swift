import Foundation
import GitwallCore
import Testing
@testable import GitwallUI

@Suite("ItemSearch")
struct ItemSearchTests {
    private func item(_ number: Int, title: String, repo: String = "dxheroes/mcp-gateway", author: String = "alice") -> WorkItem {
        WorkItem(accountID: UUID(), kind: .pullRequest, repoFullName: repo, number: number, title: title,
                 url: URL(string: "https://example.com/\(number)")!, author: UserRef(login: author),
                 createdAt: Date(), updatedAt: Date())
    }

    @Test("empty or whitespace query keeps everything")
    func emptyQuery() {
        let items = [item(1, title: "A"), item(2, title: "B")]
        #expect(ItemSearch.filter(items, query: "").count == 2)
        #expect(ItemSearch.filter(items, query: "   ").count == 2)
    }

    @Test("matches title, repository, number and author case-insensitively")
    func matches() {
        let items = [
            item(12, title: "Fix login crash"),
            item(7, title: "Docs", repo: "dxheroes/web", author: "bob"),
        ]
        #expect(ItemSearch.filter(items, query: "LOGIN").map(\.number) == [12])
        #expect(ItemSearch.filter(items, query: "web").map(\.number) == [7])
        #expect(ItemSearch.filter(items, query: "#7").map(\.number) == [7])
        #expect(ItemSearch.filter(items, query: "12").map(\.number) == [12])
        #expect(ItemSearch.filter(items, query: "bob").map(\.number) == [7])
        #expect(ItemSearch.filter(items, query: "nothing").isEmpty)
    }

    @Test("all words must match somewhere")
    func multiWord() {
        let items = [item(1, title: "Fix login crash"), item(2, title: "Login page redesign", repo: "dxheroes/web")]
        #expect(ItemSearch.filter(items, query: "login web").map(\.number) == [2])
        #expect(ItemSearch.filter(items, query: "login crash").map(\.number) == [1])
    }
}
