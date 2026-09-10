import Foundation

/// Shared container between the menu bar app and the widget extension.
public enum AppGroup {
    /// Team-ID-prefixed (macOS-style) on purpose: macOS 15+ grants such groups without a provisioning
    /// profile entitlement, whereas `group.`-style IDs need an explicit profile that automatic signing
    /// failed to produce for this Mac target. Mac App Store accepts both styles.
    public static let identifier = "ZHU9NYW7PP.cz.prokopsimek.gitwall"
    public static let urlScheme = "gitwall"
    /// WidgetKit kinds, one per size so the gallery can name each widget. Never rename: placed widgets are bound to them.
    public static let widgetKindCounter = "cz.prokopsimek.gitwall.counter"
    public static let widgetKindList = "cz.prokopsimek.gitwall.list"
    public static let widgetKindBoard = "cz.prokopsimek.gitwall.board"
    public static let widgetKindWideBoard = "cz.prokopsimek.gitwall.wideboard"
    public static let widgetKinds = [widgetKindCounter, widgetKindList, widgetKindBoard, widgetKindWideBoard]

    /// Root of the shared container. `nil` when the process is not entitled to the group.
    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
