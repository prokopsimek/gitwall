import Foundation

/// Shared container between the menu bar app and the widget extension.
public enum AppGroup {
    /// Team-ID-prefixed (macOS-style) on purpose: macOS 15+ grants such groups without a provisioning
    /// profile entitlement, whereas `group.`-style IDs need an explicit profile that automatic signing
    /// failed to produce for this Mac target. Mac App Store accepts both styles.
    public static let identifier = "ZHU9NYW7PP.cz.prokopsimek.gitwall"
    public static let urlScheme = "gitwall"

    /// Root of the shared container. `nil` when the process is not entitled to the group.
    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
