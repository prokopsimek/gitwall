import Foundation

/// The first-run walkthrough. Kept here, not in the app target, so the order and the rules about which step
/// can be left are covered by tests.
public enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {
    case welcome
    case account
    case repositories
    case presets
    case notifications
    case startup
    case widget

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .account: "Connect an account"
        case .repositories: "Choose repositories"
        case .presets: "Your views"
        case .notifications: "Notifications"
        case .startup: "Startup"
        case .widget: "Add a widget"
        }
    }

    public var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .account: "person.crop.circle.badge.plus"
        case .repositories: "folder"
        case .presets: "slider.horizontal.3"
        case .notifications: "bell"
        case .startup: "power"
        case .widget: "square.grid.2x2"
        }
    }

    public var next: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    public var previous: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    /// Steps the user cannot skip past until they did something. Only the account matters: everything
    /// afterwards has a sensible default, and a walkthrough that traps people is worse than one they skim.
    public func canContinue(with config: AppConfig) -> Bool {
        switch self {
        case .account: !config.accounts.isEmpty
        default: true
        }
    }

    /// Where to resume when the walkthrough is reopened with a partly configured app.
    public static func resume(with config: AppConfig) -> OnboardingStep {
        if config.accounts.isEmpty { return .welcome }
        if config.accounts.allSatisfy(\.sources.isEmpty) { return .repositories }
        return .presets
    }
}
