import Foundation
import Testing
@testable import GitwallCore

@Suite("Launch at login")
struct LaunchAtLoginTests {
    private func account() -> Account {
        Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub")
    }

    @Test("a fresh installation switches it on for itself")
    func freshInstallation() {
        #expect(AppConfig.empty.shouldRegisterAtLogin)
    }

    @Test("it happens once, so a user who switches it off keeps it off")
    func onlyOnce() {
        var config = AppConfig.empty
        config.settings.launchAtLoginConfigured = true
        #expect(!config.shouldRegisterAtLogin)
    }

    @Test("an installation that predates the flag is left as the user set it")
    func existingInstallation() {
        let withAccount = AppConfig(accounts: [account()])
        #expect(!withAccount.shouldRegisterAtLogin)

        var onboarded = AppConfig.empty
        onboarded.settings.onboardingCompleted = true
        #expect(!onboarded.shouldRegisterAtLogin)
    }
}
