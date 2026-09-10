import AppKit
import GitwallCore
import GitwallUI
import SwiftUI

/// Scrollable list of items shared by the popover and the main window.
struct ItemListView: View {
    let items: [WorkItem]
    let environment: AppEnvironment
    var style: WorkItemRow.Style = .regular

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    ItemRowButton(item: item, environment: environment, style: style)
                    Divider().padding(.leading, 42)
                }
            }
        }
    }
}

/// One clickable row: opens the item in the browser, offers copy actions in the context menu.
struct ItemRowButton: View {
    let item: WorkItem
    let environment: AppEnvironment
    var style: WorkItemRow.Style = .regular
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(item.url)
        } label: {
            WorkItemRow(
                item: item,
                avatar: environment.avatar(for: item.author.avatarURL).map { Image(nsImage: $0) },
                style: style,
                isNew: environment.newItemIDs.contains(item.id)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in Browser") { NSWorkspace.shared.open(item.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(item.title) (\(item.repoFullName)#\(item.number))", forType: .string)
            }
        }
        .accessibilityIdentifier("item-\(item.repoFullName)-\(item.number)")
    }
}

/// Why a list is empty. Computed once in `AppEnvironment.listState(for:)` so popover and window agree.
enum EmptyStateKind: Equatable {
    case containerUnavailable
    case noAccounts
    case noPresets
    case noRepositories
    case loading
    case nothingMatches(presetName: String)
}

struct EmptyStateView: View {
    let title: String
    let symbol: String
    let message: String
    var action: (String, () -> Void)?

    init(title: String, symbol: String, message: String, action: (String, () -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.action = action
    }

    init(kind: EmptyStateKind, environment: AppEnvironment) {
        switch kind {
        case .containerUnavailable:
            self.init(title: "Shared container unavailable", symbol: "exclamationmark.triangle",
                      message: "Gitwall cannot store data. Reinstalling the app usually fixes this.")
        case .noAccounts:
            self.init(title: "Connect GitHub to get started", symbol: "person.crop.circle.badge.plus",
                      message: "Add an account with a personal access token, choose repositories, and your pull requests and issues appear here and in desktop widgets.",
                      action: ("Add Account…", { environment.openSettings(.accounts) }))
        case .noPresets:
            self.init(title: "No presets", symbol: "slider.horizontal.3",
                      message: "A preset decides which items are shown. Create one in Settings.",
                      action: ("Open Settings", { environment.openSettings(.presets) }))
        case .noRepositories:
            self.init(title: "No repositories selected", symbol: "folder.badge.plus",
                      message: "Choose which repositories or organizations Gitwall should watch.",
                      action: ("Choose Repositories…", { environment.openSettings(.repositories) }))
        case .loading:
            self.init(title: "Loading…", symbol: "arrow.triangle.2.circlepath", message: "Fetching the latest activity.")
        case .nothingMatches(let presetName):
            self.init(title: "Nothing here", symbol: "checkmark.circle", message: "No open items match “\(presetName)”.")
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if let action {
                Button(action.0, action: action.1).padding(.top, 4)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
