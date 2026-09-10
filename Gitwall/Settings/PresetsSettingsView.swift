import GitwallCore
import GitwallUI
import SwiftUI

struct PresetsSettingsView: View {
    @Bindable var environment: AppEnvironment
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(environment.config.presets) { preset in
                        Label {
                            HStack {
                                Text(preset.name)
                                Spacer()
                                Text("\(environment.count(for: preset))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: preset.icon)
                        }
                        .tag(preset.id)
                    }
                    .onMove { environment.movePresets(from: $0, to: $1) }
                }
                .listStyle(.inset)
                HStack(spacing: 8) {
                    Button {
                        let preset = Preset(name: "New preset")
                        environment.addPreset(preset)
                        selection = preset.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        if let preset = selected {
                            var copy = preset
                            copy.id = UUID()
                            copy.name += " copy"
                            copy.showCountInMenuBar = false
                            environment.addPreset(copy)
                            selection = copy.id
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(selected == nil)
                    Button {
                        if let preset = selected {
                            environment.removePreset(preset)
                            selection = environment.config.presets.first?.id
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selected == nil)
                    Spacer()
                    Button {
                        environment.showWidgetHelp()
                    } label: {
                        Label("Add Widget…", systemImage: "rectangle.3.group")
                    }
                    .help("How to place Gitwall widgets on the desktop")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

            Group {
                if let preset = selected {
                    PresetEditor(environment: environment, preset: preset)
                        .id(preset.id)
                } else {
                    ContentUnavailableView(
                        "Presets",
                        systemImage: "slider.horizontal.3",
                        description: Text("A preset decides which pull requests and issues a widget shows. Each widget on your desktop picks one preset.")
                    )
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = environment.config.presets.first?.id } }
    }

    private var selected: Preset? {
        environment.config.preset(id: selection ?? UUID())
    }
}

private struct PresetEditor: View {
    @Bindable var environment: AppEnvironment
    @State var preset: Preset
    @State private var labelsAny: String
    @State private var labelsNone: String

    init(environment: AppEnvironment, preset: Preset) {
        self.environment = environment
        _preset = State(initialValue: preset)
        _labelsAny = State(initialValue: preset.filter.labelsAny.joined(separator: ", "))
        _labelsNone = State(initialValue: preset.filter.labelsNone.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                Picker("Icon", selection: $preset.icon) {
                    ForEach(PresetIcons.all, id: \.self) { icon in
                        Image(systemName: icon).tag(icon)
                    }
                }
                .pickerStyle(.menu)
                HStack {
                    Text("Show")
                    Toggle("Pull requests", isOn: kindBinding(.pullRequest))
                    Toggle("Issues", isOn: kindBinding(.issue))
                }
                Picker("Sort by", selection: $preset.sort) {
                    Text("Latest activity").tag(SortOrder.lastActivity)
                    Text("Newest created").tag(SortOrder.newestCreated)
                    Text("Oldest created").tag(SortOrder.oldestCreated)
                }
                Toggle("Show count next to the menu bar icon", isOn: $preset.showCountInMenuBar)
            } header: {
                HStack {
                    Text("Preset")
                    Spacer()
                    Text("\(environment.items(for: preset).count) items match now")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section("Accounts and repositories") {
                if environment.config.accounts.isEmpty {
                    Text("Add an account to narrow the preset. Without accounts the preset matches everything.")
                        .foregroundStyle(.secondary)
                }
                Toggle("All accounts and repositories", isOn: Binding(
                    get: { preset.scopes.isEmpty },
                    set: { all in
                        preset.scopes = all ? [] : environment.config.accounts.map { PresetScope(accountID: $0.id) }
                    }
                ))
                if !preset.scopes.isEmpty {
                    ForEach(environment.config.accounts) { account in
                        ScopeRow(account: account, scope: scopeBinding(for: account))
                    }
                }
            }

            Section("Relation to me") {
                Toggle("Authored by me", isOn: relationBinding(.authoredByMe))
                Toggle("Review requested from me", isOn: relationBinding(.reviewRequestedFromMe))
                Toggle("Assigned to me", isOn: relationBinding(.assignedToMe))
                Text("Leave all off to show everyone's items. Several checked options combine with OR.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pull request state") {
                Toggle("Include drafts", isOn: $preset.filter.includeDrafts)
                MultiToggleRow(title: "Review", options: [
                    (ReviewState.approved, "Approved"), (.changesRequested, "Changes requested"), (.pending, "Pending"), (ReviewState.none, "No review"),
                ], selection: $preset.filter.reviewStates)
                MultiToggleRow(title: "Checks", options: [
                    (CIState.success, "Passed"), (.failure, "Failed"), (.running, "Running"), (CIState.none, "None"),
                ], selection: $preset.filter.ciStates)
                MultiToggleRow(title: "Merge", options: [
                    (MergeState.clean, "Mergeable"), (.conflict, "Conflict"), (.unknown, "Unknown"),
                ], selection: $preset.filter.mergeStates)
            }

            Section("More filters") {
                TextField("Any of these labels (comma separated)", text: $labelsAny)
                    .onChange(of: labelsAny) { _, value in preset.filter.labelsAny = split(value) }
                TextField("None of these labels (comma separated)", text: $labelsNone)
                    .onChange(of: labelsNone) { _, value in preset.filter.labelsNone = split(value) }
                Picker("Updated within", selection: Binding(
                    get: { preset.filter.updatedWithinDays ?? 0 },
                    set: { preset.filter.updatedWithinDays = $0 == 0 ? nil : $0 }
                )) {
                    Text("Any time").tag(0)
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                TextField("Milestone", text: Binding(
                    get: { preset.filter.milestone ?? "" },
                    set: { preset.filter.milestone = $0.isEmpty ? nil : $0 }
                ))
                TextField("Title, repository or #number contains", text: Binding(
                    get: { preset.filter.text ?? "" },
                    set: { preset.filter.text = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("Notifications") {
                ForEach(NotificationEvent.allCases, id: \.self) { event in
                    Toggle(eventTitle(event), isOn: Binding(
                        get: { preset.notifications.contains(event) },
                        set: { on in
                            if on { preset.notifications.insert(event) } else { preset.notifications.remove(event) }
                        }
                    ))
                }
                Text("Notifications fire for items that match this preset. All are on by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: preset) { _, newValue in environment.updatePreset(newValue) }
    }

    private func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func kindBinding(_ kind: ItemKind) -> Binding<Bool> {
        Binding(
            get: { preset.kinds.contains(kind) },
            set: { on in
                if on { preset.kinds.insert(kind) } else if preset.kinds.count > 1 { preset.kinds.remove(kind) }
            }
        )
    }

    private func relationBinding(_ relation: Relation) -> Binding<Bool> {
        Binding(
            get: { preset.filter.relations.contains(relation) },
            set: { on in
                if on { preset.filter.relations.insert(relation) } else { preset.filter.relations.remove(relation) }
            }
        )
    }

    private func scopeBinding(for account: Account) -> Binding<PresetScope?> {
        Binding(
            get: { preset.scopes.first { $0.accountID == account.id } },
            set: { scope in
                preset.scopes.removeAll { $0.accountID == account.id }
                if let scope { preset.scopes.append(scope) }
            }
        )
    }

    private func eventTitle(_ event: NotificationEvent) -> String {
        switch event {
        case .newItem: "New item"
        case .reviewRequested: "Review requested from me"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .ciFailed: "Checks failed"
        case .merged: "Merged"
        case .closed: "Closed or merged"
        }
    }
}

private struct ScopeRow: View {
    let account: Account
    @Binding var scope: PresetScope?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(account.displayName, isOn: Binding(
                get: { scope != nil },
                set: { scope = $0 ? PresetScope(accountID: account.id) : nil }
            ))
            if scope != nil {
                let repos = account.sources.compactMap { source -> String? in
                    if case .repository(let name) = source { return name }
                    return nil
                }
                if !repos.isEmpty {
                    Toggle("Only selected repositories", isOn: Binding(
                        get: { scope?.repositories != nil },
                        set: { scope?.repositories = $0 ? Set(repos) : nil }
                    ))
                    .padding(.leading, 20)
                    if scope?.repositories != nil {
                        ForEach(repos, id: \.self) { repo in
                            Toggle(repo, isOn: Binding(
                                get: { scope?.repositories?.contains(repo) ?? false },
                                set: { on in
                                    var set = scope?.repositories ?? []
                                    if on { set.insert(repo) } else { set.remove(repo) }
                                    scope?.repositories = set
                                }
                            ))
                            .padding(.leading, 40)
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

private struct MultiToggleRow<Value: Hashable>: View {
    let title: String
    let options: [(Value, String)]
    @Binding var selection: Set<Value>

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 60, alignment: .leading)
            ForEach(options, id: \.0) { option in
                Toggle(option.1, isOn: Binding(
                    get: { selection.contains(option.0) },
                    set: { on in if on { selection.insert(option.0) } else { selection.remove(option.0) } }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
    }
}
