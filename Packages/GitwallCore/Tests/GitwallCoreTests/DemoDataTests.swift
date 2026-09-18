import Foundation
import GitwallCore
import Testing

/// Demo content drives the `--debug-demo` launch mode used for App Store screenshots.
/// It must look like a real, healthy installation without touching any user data.
@Suite("DemoData")
struct DemoDataTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("every item belongs to a configured account and has a stable id")
    func itemsBelongToAccounts() {
        let config = DemoData.config
        let snapshot = DemoData.snapshot(now: now)
        let accountIDs = Set(config.accounts.map(\.id))
        #expect(config.accounts.count == 2)
        #expect(Set(config.accounts.map(\.kind)) == [.github, .gitlab])
        #expect(!snapshot.items.isEmpty)
        #expect(snapshot.items.allSatisfy { accountIDs.contains($0.accountID) })
        #expect(Set(snapshot.items.map(\.id)).count == snapshot.items.count)
        #expect(Set(snapshot.accountStatus.keys) == accountIDs)
        #expect(snapshot.accountStatus.values.allSatisfy { $0.state == .ok })
    }

    @Test("default presets all show something")
    func presetsHaveItems() {
        let config = DemoData.config
        let snapshot = DemoData.snapshot(now: now)
        #expect(config.presets.count >= 3)
        for preset in config.presets {
            let items = FilterEngine.items(matching: preset, in: snapshot.items, accounts: config.accounts, now: now)
            #expect(!items.isEmpty, "preset \(preset.name) is empty")
        }
    }

    @Test("items are recent relative to the given clock and cover the status palette")
    func itemsAreVaried() {
        let snapshot = DemoData.snapshot(now: now)
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.items.allSatisfy { $0.updatedAt <= now && $0.updatedAt > now.addingTimeInterval(-30 * 86_400) })
        let pulls = snapshot.items.filter { $0.kind == .pullRequest }
        #expect(Set(pulls.compactMap(\.reviewState)).isSuperset(of: [.approved, .changesRequested, .pending]))
        #expect(Set(pulls.compactMap(\.ciState)).isSuperset(of: [.success, .failure, .running]))
        #expect(pulls.contains { $0.mergeState == .conflict })
        #expect(pulls.contains { $0.isDraft })
        #expect(snapshot.items.contains { $0.kind == .issue })
    }

    @Test("demo config is deterministic across calls")
    func deterministic() {
        #expect(DemoData.config == DemoData.config)
        #expect(DemoData.snapshot(now: now) == DemoData.snapshot(now: now))
    }

    @Test("refresh arrivals are new review requests that a subscribed preset is notified about")
    func arrivalsNotify() throws {
        let before = DemoData.snapshot(now: now)
        let after = DemoData.snapshot(now: now.addingTimeInterval(60), arrivals: 1)
        #expect(after.items.count == before.items.count + 1)
        #expect(DemoData.snapshot(now: now, arrivals: DemoData.arrivalCount + 3).items.count == before.items.count + DemoData.arrivalCount)

        var presets = DemoData.presets
        let index = try #require(presets.firstIndex { $0.name == "Waiting for my review" })
        presets[index].notifications = [.reviewRequested]
        let changes = SnapshotDiff.changes(from: before, to: after, accounts: DemoData.config.accounts)
        let routed = SnapshotDiff.notifications(for: changes, presets: presets, accounts: DemoData.config.accounts, previous: before, now: now)
        #expect(routed.count == 1)
        #expect(routed.first?.change.event == .reviewRequested)
    }

    @Test("sample accounts have repositories to discover")
    func discovery() {
        for account in DemoData.config.accounts {
            let found = DemoData.discovery(for: account.id)
            #expect(!found.repositories.isEmpty)
            #expect(!found.containers.isEmpty)
        }
        #expect(DemoData.discovery(for: UUID()).repositories.isEmpty)
    }

    @Test("widgets offer the sample presets until an account exists")
    func widgetPresets() {
        #expect(DemoData.widgetPresets(for: .empty) == DemoData.presets)
        let own = Preset(name: "Mine", kinds: [.pullRequest])
        let configured = AppConfig(accounts: [DemoData.github], presets: [own])
        #expect(DemoData.widgetPresets(for: configured) == [own])
    }
}
