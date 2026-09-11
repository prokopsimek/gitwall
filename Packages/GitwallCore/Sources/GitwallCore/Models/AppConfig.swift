import Foundation

public struct AppSettings: Codable, Hashable, Sendable {
    public static let refreshIntervalChoices = [1, 2, 5, 15, 30]

    public var refreshIntervalMinutes: Int
    public var onboardingCompleted: Bool
    /// Set once the app has switched Launch at login on for itself, so that a later "off" is never undone.
    public var launchAtLoginConfigured: Bool

    public init(
        refreshIntervalMinutes: Int = 5,
        onboardingCompleted: Bool = false,
        launchAtLoginConfigured: Bool = false
    ) {
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.onboardingCompleted = onboardingCompleted
        self.launchAtLoginConfigured = launchAtLoginConfigured
    }

    private enum CodingKeys: String, CodingKey {
        case refreshIntervalMinutes, onboardingCompleted, launchAtLoginConfigured
    }

    /// Every key is optional, so a `config.json` written by an older build keeps loading.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 5
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        launchAtLoginConfigured = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginConfigured) ?? false
    }

    public var refreshInterval: TimeInterval { TimeInterval(refreshIntervalMinutes * 60) }
}

/// Everything configurable, minus secrets. Shared with the widget through the App Group.
public struct AppConfig: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var accounts: [Account]
    public var presets: [Preset]
    public var settings: AppSettings

    public init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        accounts: [Account] = [],
        presets: [Preset] = [],
        settings: AppSettings = AppSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.presets = presets
        self.settings = settings
    }

    public static let empty = AppConfig()

    public func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    public func preset(id: UUID) -> Preset? {
        presets.first { $0.id == id }
    }

    /// A menu bar app shows nothing while it is not running, so a fresh installation switches Launch at login
    /// on for itself at the first launch. Exactly once: `launchAtLoginConfigured` records that it happened, and
    /// an installation that predates the flag is left alone, because whatever it has now is the user's choice.
    public var shouldRegisterAtLogin: Bool {
        guard !settings.launchAtLoginConfigured else { return false }
        return accounts.isEmpty && !settings.onboardingCompleted
    }
}
