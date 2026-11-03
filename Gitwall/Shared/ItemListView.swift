import AppKit
import GitwallCore
import GitwallUI
import SwiftUI

/// Scrollable list of items shared by the popover and the main window.
struct ItemListView: View {
    let items: [WorkItem]
    let environment: AppEnvironment
    var style: WorkItemRow.Style = .regular
    /// With Detail (main window): a click selects and shows Detail, a double click opens the item, ↑↓ move the
    /// selection. Without it (popover): a click opens the item, as before.
    var detail: DetailModel? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        if let detail {
            selectableList(detail)
        } else {
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

    private func selectableList(_ detail: DetailModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        SelectableItemRow(item: item, environment: environment, style: style, detail: detail) {
                            isFocused = true
                        }
                        .id(item.id)
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up: detail.move(by: -1)
                case .down: detail.move(by: 1)
                default: break
                }
            }
            .onChange(of: detail.selectedItemID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
            .onChange(of: items.map(\.id), initial: true) { _, ids in detail.visibleItemIDs = ids }
        }
    }
}

/// A row of the main window's list: selected on a click, opened on a double click.
private struct SelectableItemRow: View {
    let item: WorkItem
    let environment: AppEnvironment
    let style: WorkItemRow.Style
    let detail: DetailModel
    let onClick: () -> Void
    @State private var hovering = false

    private var isSelected: Bool { detail.selectedItemID == item.id }

    var body: some View {
        WorkItemRow(
            item: item,
            avatar: environment.avatar(for: item.author.avatarURL).map { Image(nsImage: $0) },
            style: style,
            isNew: environment.newItemIDs.contains(item.id),
            isChanged: environment.details.hasChanged(item)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { environment.open(item) }
        .simultaneousGesture(TapGesture().onEnded {
            detail.show(item.id)
            onClick()
        })
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show Detail") { detail.show(item.id) }
            ItemContextMenu(item: item, environment: environment)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction {
            detail.show(item.id)
            onClick()
        }
        .accessibilityAction(named: "Open in Browser") { environment.open(item) }
        .accessibilityIdentifier("item-\(item.repoFullName)-\(item.number)")
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return hovering ? Color.primary.opacity(0.06) : .clear
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
            environment.open(item)
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
        .contextMenu { ItemContextMenu(item: item, environment: environment) }
        .accessibilityIdentifier("item-\(item.repoFullName)-\(item.number)")
    }
}

/// Open and copy, the same for every list.
private struct ItemContextMenu: View {
    let item: WorkItem
    let environment: AppEnvironment

    var body: some View {
        Button("Open in Browser") { environment.open(item) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        }
        Button("Copy Title") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(item.title) (\(item.repoFullName)#\(item.number))", forType: .string)
        }
    }
}

/// Why a list is empty. Computed once in `AppEnvironment.listState(for:)` so popover and window agree.
enum EmptyStateKind: Equatable {
    case containerUnavailable
    case noAccounts
    case noPresets
    /// None of the preset's accounts watches anything; `account` is the first of them.
    case noRepositories(account: Account)
    case loading
    /// `idle` is an account of the preset that watches nothing: its items are missing whatever the filter says.
    case nothingMatches(presetName: String, idle: Account?)
}

struct EmptyStateView: View {
    let title: String
    let symbol: String
    let message: String
    var action: (String, () -> Void)?
    /// Offered under the action while no account exists (`EmptyStateKind.noAccounts`).
    var sampleData: AppEnvironment?

    init(title: String, symbol: String, message: String, action: (String, () -> Void)? = nil, sampleData: AppEnvironment? = nil) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.action = action
        self.sampleData = sampleData
    }

    init(kind: EmptyStateKind, environment: AppEnvironment) {
        switch kind {
        case .containerUnavailable:
            self.init(title: "Shared container unavailable", symbol: "exclamationmark.triangle",
                      message: "Gitwall cannot store data. Reinstalling the app usually fixes this.")
        case .noAccounts:
            self.init(title: "Connect GitHub or GitLab to get started", symbol: "person.crop.circle.badge.plus",
                      message: "Sign in or add a personal access token, choose repositories, and your pull requests and issues appear here and in desktop widgets.",
                      action: ("Add Account…", { environment.openSettings(.accounts) }),
                      sampleData: environment)
        case .noPresets:
            self.init(title: "No presets", symbol: "slider.horizontal.3",
                      message: "A preset decides which items are shown. Create one in Settings.",
                      action: ("Open Settings", { environment.openSettings(.presets) }))
        case .noRepositories(let account):
            self.init(title: "No repositories selected", symbol: "folder.badge.plus",
                      message: "\(account.displayName) watches no repositories yet, so nothing is fetched for it. Choose the repositories or organizations Gitwall should watch.",
                      action: ("Choose Repositories…", { environment.openSettings(.repositories, accountID: account.id) }))
        case .loading:
            self.init(title: "Loading…", symbol: "arrow.triangle.2.circlepath", message: "Fetching the latest activity.")
        case .nothingMatches(let presetName, nil):
            self.init(title: "Nothing here", symbol: "checkmark.circle", message: "No open items match “\(presetName)”.")
        case .nothingMatches(let presetName, let idle?):
            self.init(title: "Nothing here", symbol: "checkmark.circle",
                      message: "No open items match “\(presetName)”. \(idle.displayName) watches no repositories yet, so its items are not fetched.",
                      action: ("Choose Repositories…", { environment.openSettings(.repositories, accountID: idle.id) }))
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
            if let sampleData {
                SampleDataOffer(environment: sampleData, alignment: .center)
                    .frame(maxWidth: 420)
                    .padding(.top, 2)
            }
            Spacer()
        }
        // The texts take the height they need at the offered width. Offered none, which is how a window asks for
        // its smallest size, they wrap one letter per line and report a height of two thousand points; the split
        // view of the main window then lays itself out that tall and its sidebar and header leave the window.
        .frame(minWidth: 280)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
