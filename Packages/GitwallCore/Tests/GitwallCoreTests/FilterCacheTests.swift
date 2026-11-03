import Foundation
import Testing
@testable import GitwallCore

@Suite("Filter cache")
struct FilterCacheTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_040)

    private func item(_ number: Int, updated: Date) -> WorkItem {
        WorkItem(accountID: UUID(), kind: .pullRequest, repoFullName: "acme/app", number: number, title: "#\(number)",
                 url: URL(string: "https://example.com/\(number)")!, author: UserRef(login: "a"),
                 createdAt: updated, updatedAt: updated)
    }

    @Test("a saved preset is worked out once and then answered from the cache")
    func caches() {
        var cache = FilterCache()
        let preset = Preset(name: "All")
        var computed = 0
        let first = cache.items(for: preset, saved: preset, now: start) { computed += 1; return [item(1, updated: start)] }
        let second = cache.items(for: preset, saved: preset, now: start.addingTimeInterval(5)) { computed += 1; return [] }
        #expect(computed == 1)
        #expect(first == second)
    }

    @Test("an unsaved copy, as the preset editor holds, is worked out every time and never stored")
    func bypassesUnsavedCopy() {
        var cache = FilterCache()
        let saved = Preset(name: "All")
        var draft = saved
        draft.name = "All, being edited"
        var computed = 0
        _ = cache.items(for: draft, saved: saved, now: start) { computed += 1; return [] }
        _ = cache.items(for: draft, saved: saved, now: start) { computed += 1; return [] }
        _ = cache.items(for: draft, saved: nil, now: start) { computed += 1; return [] }
        #expect(computed == 3)
        #expect(cache.count == 0)
    }

    @Test("one entry per preset: a changed preset replaces the old answer")
    func onePerPreset() {
        var cache = FilterCache()
        var preset = Preset(name: "All")
        _ = cache.items(for: preset, saved: preset, now: start) { [] }
        preset.filter = ItemFilter(query: "is:pr")
        var computed = 0
        _ = cache.items(for: preset, saved: preset, now: start) { computed += 1; return [] }
        #expect(computed == 1)
        #expect(cache.count == 1)
        _ = cache.items(for: Preset(name: "Other"), saved: nil, now: start) { [] }
        #expect(cache.count == 1)
    }

    @Test("answers expire with the minute, so an age filter keeps moving while nothing syncs")
    func expiresByMinute() {
        var cache = FilterCache()
        let preset = Preset(name: "This week", kinds: [.pullRequest], filter: ItemFilter(updatedWithinDays: 7))
        // Seven days old minus thirty seconds: inside the week now, outside it a minute later.
        let items = [item(1, updated: start.addingTimeInterval(-7 * 86_400 + 30))]
        func answer(at now: Date) -> [WorkItem] {
            cache.items(for: preset, saved: preset, now: now) {
                FilterEngine.items(matching: preset, in: items, accounts: [], now: now)
            }
        }
        #expect(answer(at: start).count == 1)
        #expect(answer(at: start.addingTimeInterval(15)).count == 1)
        #expect(answer(at: start.addingTimeInterval(61)).isEmpty)
    }

    @Test("emptying forgets every answer")
    func removeAll() {
        var cache = FilterCache()
        let preset = Preset(name: "All")
        _ = cache.items(for: preset, saved: preset, now: start) { [] }
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test("only changes outside the walls reach the widgets and the cache")
    func configChanges() {
        let config = AppConfig(presets: [Preset(name: "All")])
        var wallsOnly = config
        wallsOnly.walls = [Wall(name: "Desk")]
        #expect(!wallsOnly.differsOutsideWalls(from: config))
        var presets = wallsOnly
        presets.presets[0].name = "Everything"
        #expect(presets.differsOutsideWalls(from: wallsOnly))
        var accounts = config
        accounts.accounts = [Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub")]
        #expect(accounts.differsOutsideWalls(from: config))
        var settings = config
        settings.settings.refreshIntervalMinutes = 2
        #expect(settings.differsOutsideWalls(from: config))
    }
}
