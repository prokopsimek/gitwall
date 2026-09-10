import GitwallCore
import GitwallUI
import SwiftUI

struct MainWindowView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var state: MainWindowState
    @State private var query = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $state.showingWidgetHelp) {
            AddWidgetHelpSheet()
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { environment.selectedPreset?.id },
                set: { if let id = $0 { environment.selectedPresetID = id } }
            )) {
                Section("Presets") {
                    ForEach(environment.config.presets) { preset in
                        HStack {
                            Label(preset.name, systemImage: preset.icon)
                                .lineLimit(1)
                            Spacer()
                            Text("\(environment.count(for: preset))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .tag(preset.id)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    environment.openSettings(.presets)
                } label: {
                    Label("Edit Presets…", systemImage: "slider.horizontal.3")
                }
                Button {
                    state.showingWidgetHelp = true
                } label: {
                    Label("Add Widget to Desktop…", systemImage: "rectangle.3.group")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let preset = environment.selectedPreset {
                Label(preset.name, systemImage: preset.icon)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            } else {
                Text("Gitwall").font(.title3.weight(.semibold))
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search title, repository, #number, author", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 320)
            .accessibilityIdentifier("main-search")
            if environment.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await environment.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now (⌘R)")
            .disabled(environment.isRefreshing)
            Button {
                environment.openSettings(environment.needsOnboarding ? .accounts : .presets)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch environment.listState(for: environment.selectedPreset) {
        case .items(let items):
            let visible = ItemSearch.filter(items, query: query)
            if visible.isEmpty {
                EmptyStateView(title: "No matches", symbol: "magnifyingglass",
                               message: "Nothing in “\(environment.selectedPreset?.name ?? "")” matches “\(query)”.")
            } else {
                ItemListView(items: visible, environment: environment, style: .regular)
            }
        case .empty(let kind):
            EmptyStateView(kind: kind, environment: environment)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let preset = environment.selectedPreset {
                Text("\(environment.count(for: preset)) items")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let fetchedAt = environment.snapshot?.fetchedAt {
                Text("Synced \(fetchedAt, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let (account, status) = environment.accountsNeedingAttention.first {
                Button {
                    environment.openSettings(.accounts)
                } label: {
                    Label("\(account.displayName): \(status.message ?? status.state.rawValue)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            } else if let error = environment.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
            }
            Spacer()
            Text("\(environment.config.accounts.count) account\(environment.config.accounts.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
