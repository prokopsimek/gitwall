import GitwallCore
import GitwallUI
import SwiftUI

/// Compact list shown under the status item. The main window offers the same data with search.
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
                .frame(maxWidth: 240)
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
            .help("Refresh now")
            .disabled(environment.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            Button {
                environment.openMainWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .help("Open Gitwall window")
            Button {
                environment.openSettings(environment.needsOnboarding ? .accounts : .presets)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch environment.listState(for: environment.selectedPreset) {
        case .items(let items):
            ItemListView(items: items, environment: environment, style: .regular)
        case .empty(let kind):
            EmptyStateView(kind: kind, environment: environment)
        }
    }

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
