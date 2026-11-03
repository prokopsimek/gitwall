import Foundation
import Testing
@testable import GitwallCore

@Suite("DetailCache")
struct DetailCacheTests {
    typealias S = DetailSupport

    @Test("a detail is valid while its item keeps the same updatedAt")
    func validWhileUnchanged() {
        var cache = DetailCache()
        var item = S.pull()
        cache.store(S.detail(for: item), accountID: S.account.id)

        #expect(cache.detail(for: item) == S.detail(for: item))
        item.updatedAt = S.now
        #expect(cache.detail(for: item) == nil)
    }

    @Test("a part that failed in passing is not kept, so opening the item again tries again")
    func passingFailuresAreNotKept() {
        var cache = DetailCache()
        let item = S.pull()
        var detail = S.detail(for: item)
        detail.checks = .failure(.failed("Bad gateway"))

        cache.store(detail, accountID: S.account.id)

        #expect(cache.detail(for: item) == nil)
    }

    @Test("a missing permission is kept until the account's credential changes")
    func missingPermissionUntilCredentialChanges() {
        var cache = DetailCache()
        let item = S.pull()
        let other = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "Other")
        var refused = S.detail(for: item)
        refused.checks = .failure(.missingPermission)
        var otherItem = S.pull(9, account: other)
        otherItem.updatedAt = S.now
        cache.store(refused, accountID: S.account.id)
        cache.store(S.detail(for: otherItem), accountID: other.id)

        #expect(cache.detail(for: item) == refused)
        cache.forget(accountID: S.account.id)
        #expect(cache.detail(for: item) == nil)
        #expect(cache.detail(for: otherItem) != nil)
    }

    @Test("only the most recently stored details stay")
    func limit() {
        var cache = DetailCache(limit: 2)
        let items = [S.pull(1), S.pull(2), S.pull(3)]
        for item in items { cache.store(S.detail(for: item), accountID: S.account.id) }

        #expect(cache.detail(for: items[0]) == nil)
        #expect(cache.detail(for: items[1]) != nil)
        #expect(cache.detail(for: items[2]) != nil)
    }

    @Test("storing again moves a detail to the back of the line")
    func refreshKeeps() {
        var cache = DetailCache(limit: 2)
        let items = [S.pull(1), S.pull(2), S.pull(3)]
        cache.store(S.detail(for: items[0]), accountID: S.account.id)
        cache.store(S.detail(for: items[1]), accountID: S.account.id)
        cache.store(S.detail(for: items[0]), accountID: S.account.id)
        cache.store(S.detail(for: items[2]), accountID: S.account.id)

        #expect(cache.detail(for: items[0]) != nil)
        #expect(cache.detail(for: items[1]) == nil)
    }
}
