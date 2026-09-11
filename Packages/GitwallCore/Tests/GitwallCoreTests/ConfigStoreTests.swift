import Foundation
import Testing
@testable import GitwallCore

@Suite("ConfigStore")
struct ConfigStoreTests {
    private func makeStore() -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitwall-config-\(UUID().uuidString)", isDirectory: true)
        return (ConfigStore(directoryURL: dir), dir)
    }

    @Test("returns the empty config when nothing is stored")
    func emptyByDefault() throws {
        let (store, _) = makeStore()
        #expect(try store.load() == .empty)
    }

    @Test("round-trips accounts, presets and settings")
    func roundTrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = Account(
            kind: .github,
            baseURL: URL(string: "https://github.com")!,
            displayName: "GitHub",
            me: UserRef(login: "prokopsimek"),
            sources: [.repository(fullName: "dxheroes/mcp-gateway"), .organization(login: "dxheroes")]
        )
        var config = AppConfig(accounts: [account], presets: Preset.defaults())
        config.settings.refreshIntervalMinutes = 2
        config.presets[0].scopes = [PresetScope(accountID: account.id, repositories: ["dxheroes/mcp-gateway"])]

        try store.save(config)

        #expect(try store.load() == config)
    }

    @Test("decodes the documented config.json layout")
    func decodesFixture() throws {
        let config = try SnapshotCoding.decode(AppConfig.self, from: Fixtures.data("config.json"))
        #expect(config.accounts.count == 1)
        #expect(config.accounts[0].kind == .github)
        #expect(config.accounts[0].sources == [.repository(fullName: "dxheroes/mcp-gateway"), .organization(login: "dxheroes")])
        #expect(config.presets.count == 2)
        #expect(config.presets[1].filter.relations == [.reviewRequestedFromMe])
        #expect(config.presets[1].notifications == [.reviewRequested, .ciFailed])
        #expect(config.settings.refreshIntervalMinutes == 5)
    }

    @Test("default presets notify about every event, and a new installation ends up with one menu bar count")
    func defaultPresets() {
        #expect(Preset.defaults().allSatisfy { $0.notifications == Set(NotificationEvent.allCases) })
        // The count belongs to the first account's review preset, see AccountPresetsTests.
        let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub")
        let config = AppConfig().adding(account, pullRequestTerm: "Pull request")
        #expect(config.presets.filter(\.showCountInMenuBar).count == 1)
    }

    @Test("a filter written before the author fields still loads, with the new fields at their defaults")
    func legacyFilterDecodes() throws {
        let legacy = #"{"relations":["reviewRequestedFromMe"],"includeDrafts":false,"labelsAny":[],"labelsNone":[],"reviewStates":[],"ciStates":[],"mergeStates":[]}"#
        let filter = try SnapshotCoding.decode(ItemFilter.self, from: Data(legacy.utf8))
        #expect(filter.relations == [.reviewRequestedFromMe])
        #expect(filter.includeDrafts == false)
        #expect(filter.authorsAny.isEmpty)
        #expect(filter.authorsNone.isEmpty)
        #expect(filter.includeDraftsRequestingMyReview)
    }

    @Test("a config.json written before per-account presets still loads, with the marker unset")
    func legacyAccountDecodes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitwall-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = #"{"schemaVersion":1,"accounts":[{"id":"6B1D0A2E-0100-4C61-9F4B-1D2A3B4C5D01","kind":"github","baseURL":"https://github.com","displayName":"GitHub (prokop)","authMethod":{"personalAccessToken":{}},"sources":[]}],"presets":[],"settings":{"refreshIntervalMinutes":5,"onboardingCompleted":true}}"#
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("config.json"))

        let config = try ConfigStore(directoryURL: dir).load()
        #expect(config.accounts.count == 1)
        #expect(config.accounts[0].defaultPresetsCreated == nil)
        #expect(config.seedingDefaultPresets { _ in "Pull request" }.presets.count == 3)
    }
}
