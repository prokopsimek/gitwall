import GitwallCore
import GitwallUI
import SwiftUI

struct PopoverView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 400, height: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if environment.config.presets.isEmpty {
                Text("Gitwall").font(.headline)
            } else {
                Picker("Preset", selection: Binding(
                    get: { environment.selectedPreset?.id ?? UUID() },
                    set: { environment.selectedPresetID = $0 }
                )) {
                    ForEach(environment.config.presets) { preset in
                        Label("\(preset.name) (\(environment.count(for: preset)))", systemImage: preset.icon)
                            .tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityIdentifier("preset-picker")
            }
            Spacer()
            if environment.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await environment.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(environment.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            Button {
                environment.openSettings(environment.needsOnboarding ? .accounts : .presets)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !environment.containerAvailable {
            emptyState("Shared container unavailable", symbol: "exclamationmark.triangle",
                       message: "Gitwall cannot store data. Reinstalling the app usually fixes this.")
        } else if environment.needsOnboarding {
            emptyState("No accounts yet", symbol: "person.crop.circle.badge.plus",
                       message: "Connect GitHub to see your pull requests and issues here and in widgets.",
                       action: ("Add Account…", { environment.openSettings(.accounts) }))
        } else if let preset = environment.selectedPreset {
            let items = environment.items(for: preset)
            if items.isEmpty {
                if environment.snapshot == nil || environment.isRefreshing {
                    emptyState("Loading…", symbol: "arrow.triangle.2.circlepath", message: "Fetching the latest activity.")
                } else if environment.config.accounts.allSatisfy(\.sources.isEmpty) {
                    emptyState("No repositories selected", symbol: "folder.badge.plus",
                               message: "Choose which repositories or organizations Gitwall should watch.",
                               action: ("Choose Repositories…", { environment.openSettings(.repositories) }))
                } else {
                    emptyState("Nothing here", symbol: "checkmark.circle",
                               message: "No open items match “\(preset.name)”.")
                }
            } else {
                list(items)
            }
        } else {
            emptyState("No presets", symbol: "slider.horizontal.3", message: "Create a preset in Settings.",
                       action: ("Open Settings", { environment.openSettings(.presets) }))
        }
    }

    private func list(_ items: [WorkItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    ItemButton(item: item, environment: environment)
                    Divider().padding(.leading, 42)
                }
            }
        }
    }

    private func emptyState(_ title: String, symbol: String, message: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1).padding(.top, 4)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let fetchedAt = environment.snapshot?.fetchedAt {
                Text("Synced \(fetchedAt, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let (account, status) = environment.accountsNeedingAttention.first {
                Button {
                    environment.openSettings(.accounts)
                } label: {
                    Label("\(account.displayName): \(shortMessage(status))", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help(status.message ?? "")
            } else if let error = environment.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func shortMessage(_ status: FetchStatus) -> String {
        switch status.state {
        case .needsReauth: "sign in again"
        case .rateLimited: "rate limited"
        case .error: "sync failed"
        case .ok: ""
        }
    }
}

private struct ItemButton: View {
    let item: WorkItem
    let environment: AppEnvironment
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(item.url)
        } label: {
            WorkItemRow(
                item: item,
                avatar: environment.avatar(for: item.author.avatarURL).map { Image(nsImage: $0) },
                style: .regular,
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
