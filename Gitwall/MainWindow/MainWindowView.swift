import GitwallCore
import GitwallUI
import SwiftUI

struct MainWindowView: View {
    /// Also how Edit › Find… finds the field (`MainWindowController.focusSearch`).
    static let searchPrompt = "Search title, repository, #number, author"

    @Bindable var environment: AppEnvironment
    @Bindable var state: MainWindowState
    let detail: DetailModel
    @State private var query = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The list has the focus when the window opens, so ↑↓, Space and ⌘C work at once; ⌘F moves it to the search
    /// field (`MainWindowController.focusSearch`) and Esc there gives it back.
    @FocusState private var isListFocused: Bool
    /// The list takes the focus once, when it first has items; AppKit would otherwise give it to the search field.
    @State private var listHadFirstFocus = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            itemColumn
                .itemDetailInspector(detail, environment: environment, preset: environment.selectedPreset)
        }
        .defaultFocus($isListFocused, true)
        .onChange(of: visibleItems.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty, !listHadFirstFocus else { return }
            listHadFirstFocus = true
            // Once the list is in the window.
            Task { isListFocused = true }
        }
        .onChange(of: environment.selectedPreset?.id) {
            detail.presetDidChange(visibleItemIDs: visibleItems.map(\.id))
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

    // MARK: Items

    private var itemColumn: some View {
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
                TextField(Self.searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .onExitCommand { isListFocused = true }
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
            Button {
                detail.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help(detail.isPresented ? "Hide Detail (⌥⌘I)" : "Show Detail (⌥⌘I)")
            .accessibilityIdentifier("toggle-detail")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The items of the selected preset that the search leaves.
    private var visibleItems: [WorkItem] {
        guard case .items(let items) = environment.listState(for: environment.selectedPreset) else { return [] }
        return ItemSearch.filter(items, query: query)
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
                ItemListView(items: visible, environment: environment, style: .regular, detail: detail, focus: $isListFocused)
            }
        case .empty(let kind):
            EmptyStateView(kind: kind, environment: environment)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let preset = environment.selectedPreset {
                // While a search narrows the list, how many of the preset's items it shows.
                let count = environment.count(for: preset)
                Group {
                    if ItemSearch.isActive(query) {
                        Text("\(visibleItems.count) of ^[\(count) item](inflect: true)")
                    } else {
                        Text("^[\(count) item](inflect: true)")
                    }
                }
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
