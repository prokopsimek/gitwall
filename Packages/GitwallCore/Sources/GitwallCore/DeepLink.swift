import Foundation

/// URLs the widget uses to talk to the app (`gitwall://…`).
public enum DeepLink: Equatable, Sendable {
    /// Open the work item with this `WorkItem.id` in the browser.
    case item(id: String)
    /// Show the popover focused on this view.
    case view(id: UUID)
    /// Trigger a sync now.
    case refresh
    /// Open the settings window, optionally on a tab (accounts, repositories, presets, general, about).
    case settings(tab: String?)

    private enum Host: String {
        case item, view, refresh, settings
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = AppGroup.urlScheme
        switch self {
        case .item(let id):
            components.host = Host.item.rawValue
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .view(let id):
            components.host = Host.view.rawValue
            components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        case .refresh:
            components.host = Host.refresh.rawValue
        case .settings(let tab):
            components.host = Host.settings.rawValue
            if let tab { components.queryItems = [URLQueryItem(name: "tab", value: tab)] }
        }
        guard let url = components.url else {
            preconditionFailure("DeepLink produced an invalid URL for \(self)")
        }
        return url
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == AppGroup.urlScheme,
              let hostString = url.host?.lowercased(),
              let host = Host(rawValue: hostString)
        else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let id = components?.queryItems?.first { $0.name == "id" }?.value

        switch host {
        case .item:
            guard let id, !id.isEmpty else { return nil }
            self = .item(id: id)
        case .view:
            guard let id, let uuid = UUID(uuidString: id) else { return nil }
            self = .view(id: uuid)
        case .refresh:
            self = .refresh
        case .settings:
            let tab = components?.queryItems?.first { $0.name == "tab" }?.value
            self = .settings(tab: (tab?.isEmpty ?? true) ? nil : tab)
        }
    }
}
