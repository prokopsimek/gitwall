import Foundation

public struct AppSettings: Codable, Hashable, Sendable {
    public static let refreshIntervalChoices = [1, 2, 5, 15, 30]

    public var refreshIntervalMinutes: Int
    public var onboardingCompleted: Bool

    public init(refreshIntervalMinutes: Int = 5, onboardingCompleted: Bool = false) {
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.onboardingCompleted = onboardingCompleted
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
}
