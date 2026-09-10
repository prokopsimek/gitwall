import Foundation

/// Shared container between the menu bar app and the widget extension.
public enum AppGroup {
    /// Team-ID-prefixed (macOS-style) on purpose: macOS 15+ grants such groups without a provisioning
    /// profile entitlement, whereas `group.`-style IDs need an explicit profile that automatic signing
    /// failed to produce for this Mac target. Mac App Store accepts both styles.
    public static let identifier = "ZHU9NYW7PP.cz.prokopsimek.gitwall"
    public static let urlScheme = "gitwall"
    /// WidgetKit kind of the configurable (AppIntent) widget. Never rename: placed widgets are bound to it.
    public static let widgetKind = "cz.prokopsimek.gitwall.preset"
    /// Kind of the original static widget. WidgetKit cannot turn a static widget into a configurable one
    /// in place, so this kind keeps serving the first preset for widgets placed with early builds.
    public static let legacyWidgetKind = "cz.prokopsimek.gitwall.overview"

    /// Root of the shared container. `nil` when the process is not entitled to the group.
    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
