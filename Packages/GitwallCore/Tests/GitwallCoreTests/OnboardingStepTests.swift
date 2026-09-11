import Foundation
import Testing
@testable import GitwallCore

@Suite("OnboardingStep")
struct OnboardingStepTests {
    let account = Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub")

    @Test("walks forward and back through every step exactly once")
    func order() {
        var visited: [OnboardingStep] = [.welcome]
        var step = OnboardingStep.welcome
        while let next = step.next {
            visited.append(next)
            step = next
        }
        #expect(visited == OnboardingStep.allCases)
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.widget.next == nil)
        #expect(OnboardingStep.presets.previous == .repositories)
    }

    @Test("only the account step blocks until something is configured")
    func gate() {
        let empty = AppConfig()
        let configured = AppConfig(accounts: [account], presets: Preset.defaults())
        #expect(!OnboardingStep.account.canContinue(with: empty))
        #expect(OnboardingStep.account.canContinue(with: configured))
        for step in OnboardingStep.allCases where step != .account {
            #expect(step.canContinue(with: empty), "\(step) should not block")
        }
    }

    @Test("resumes where the setup actually stopped")
    func resume() {
        #expect(OnboardingStep.resume(with: AppConfig()) == .welcome)
        #expect(OnboardingStep.resume(with: AppConfig(accounts: [account])) == .repositories)
        var withSources = account
        withSources.sources = [.repository(fullName: "acme/app")]
        #expect(OnboardingStep.resume(with: AppConfig(accounts: [withSources])) == .presets)
    }

    @Test("every step has a title and an icon for the sidebar")
    func labels() {
        for step in OnboardingStep.allCases {
            #expect(!step.title.isEmpty)
            #expect(!step.symbol.isEmpty)
        }
    }
}
