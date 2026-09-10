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

    @Test("default presets notify about every event and include a menu bar count")
    func defaultPresets() {
        let presets = Preset.defaults()
        #expect(presets.count == 3)
        #expect(presets.allSatisfy { $0.notifications == Set(NotificationEvent.allCases) })
        #expect(presets.contains { $0.showCountInMenuBar })
    }
}
