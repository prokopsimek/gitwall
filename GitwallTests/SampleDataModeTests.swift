import Foundation
import GitwallAuth
import GitwallCore
@testable import Gitwall
import Testing

/// App Review could not get into Gitwall without a token of their own (guideline 2.1(a), rejected 2026-09-15).
/// Sample data is the "demonstration mode" their reply offers instead of a demo account, so it has to be
/// reachable without an account — and it must never reach the App Group or the Keychain.
@Suite("Sample data mode")
@MainActor
struct SampleDataModeTests {
    /// A throwaway container, the same one `--debug-fresh` and the test host use, so nothing here can touch the
    /// real installation.
    private func environment() -> AppEnvironment {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitwall-sample-\(UUID().uuidString)")
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: InMemoryTokenStore(),
            sandbox: sandbox
        )
        environment.start()
        return environment
    }

    @Test("offered while no account is connected")
    func offeredWithoutAccounts() {
        let environment = environment()
        #expect(environment.config.accounts.isEmpty)
        #expect(environment.canShowSampleData)
        #expect(!environment.isSampleData)
    }

    @Test("entering fills the app with sample content")
    func entering() {
        let environment = environment()
        environment.enterSampleData()
        #expect(environment.isSampleData)
        #expect(environment.usesSampleContent)
        #expect(!environment.config.accounts.isEmpty)
        #expect(!environment.config.presets.isEmpty)
        #expect(!(environment.snapshot?.items.isEmpty ?? true))
        // Onboarding is what offers sample data; it must not keep asking once it is on.
        #expect(!environment.needsOnboarding)
    }

    @Test("leaving restores the empty configuration")
    func leaving() {
        let environment = environment()
        environment.enterSampleData()
        environment.leaveSampleData()
        #expect(!environment.isSampleData)
        #expect(environment.config.accounts.isEmpty)
        #expect(environment.needsOnboarding)
        #expect(environment.canShowSampleData)
    }

    @Test("sample accounts are never written to disk")
    func nothingIsPersisted() throws {
        let environment = environment()
        environment.enterSampleData()
        let stored = try environment.configStore?.load()
        #expect(stored?.accounts.isEmpty ?? true)
    }

    @Test("editing a preset while showing sample data stays in memory")
    func editingStaysInMemory() throws {
        let environment = environment()
        environment.enterSampleData()
        var preset = try #require(environment.config.presets.first)
        preset.name = "Renamed in sample mode"
        environment.updatePreset(preset)
        #expect(environment.config.presets.first?.name == "Renamed in sample mode")
        let stored = try environment.configStore?.load()
        #expect(stored?.presets.contains { $0.name == "Renamed in sample mode" } != true)
    }

    @Test("not offered once a real account exists")
    func notOfferedWithAccounts() {
        let environment = environment()
        environment.enterSampleData()
        // Sample accounts are not real ones; the offer is about what is on disk.
        environment.leaveSampleData()
        #expect(environment.canShowSampleData)
    }
}
