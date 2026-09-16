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
        // Open on the preset the user is looking at in the window or popover.
        .onAppear { if selection == nil { selection = environment.selectedPreset?.id ?? environment.config.presets.first?.id } }
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
    @State private var authorsAny: String
    @State private var authorsNone: String
    @State private var query: String

    init(environment: AppEnvironment, preset: Preset) {
        self.environment = environment
        _preset = State(initialValue: preset)
        _labelsAny = State(initialValue: preset.filter.labelsAny.joined(separator: ", "))
        _labelsNone = State(initialValue: preset.filter.labelsNone.joined(separator: ", "))
        _authorsAny = State(initialValue: preset.filter.authorsAny.joined(separator: ", "))
        _authorsNone = State(initialValue: preset.filter.authorsNone.joined(separator: ", "))
        _query = State(initialValue: preset.filter.query ?? "")
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
                if !preset.filter.includeDrafts, preset.filter.relations.contains(.reviewRequestedFromMe) {
                    Toggle("Drafts that ask for my review", isOn: $preset.filter.includeDraftsRequestingMyReview)
                    Text("Cloud agents request a review while the pull request is still a draft and cannot mark it ready themselves.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                FilterField(title: "Any of these labels", prompt: "bug, security", text: $labelsAny)
                    .onChange(of: labelsAny) { _, value in preset.filter.labelsAny = split(value) }
                FilterField(title: "None of these labels", prompt: "wontfix", text: $labelsNone)
                    .onChange(of: labelsNone) { _, value in preset.filter.labelsNone = split(value) }
                FilterField(title: "Any of these authors", prompt: "copilot-swe-agent, renovate", text: $authorsAny)
                    .onChange(of: authorsAny) { _, value in preset.filter.authorsAny = split(value) }
                FilterField(title: "None of these authors", prompt: "dependabot", text: $authorsNone)
                    .onChange(of: authorsNone) { _, value in preset.filter.authorsNone = split(value) }
                Text("Comma separated. Author logins are matched without a trailing [bot].")
                    .font(.caption).foregroundStyle(.secondary)
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
                FilterField(title: "Milestone", prompt: "Q4 2026", text: Binding(
                    get: { preset.filter.milestone ?? "" },
                    set: { preset.filter.milestone = $0.isEmpty ? nil : $0 }
                ))
                FilterField(title: "Title, repository or #number contains", prompt: "flaky", text: Binding(
                    get: { preset.filter.text ?? "" },
                    set: { preset.filter.text = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("Query") {
                QueryField(text: $query)
                    .onChange(of: query) { _, value in
                        preset.filter.query = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    }
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
                Text("Notifications fire for items that match this preset. All are off by default.")
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

/// Label above the field rather than beside it: the settings window is narrow and a long leading label used to
/// squeeze the editable part of a `TextField` in a grouped `Form` down to nothing.
private struct FilterField: View {
    let title: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// The free-form preset query, with the parser's own complaint shown under the field.
private struct QueryField: View {
    @Binding var text: String

    private var error: SearchQueryError? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if case .failure(let error) = SearchQuery.parse(text) { return error }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                "Query",
                text: $text,
                prompt: Text("assignee:@me assignee:franta-dxh,lumir-sokol"),
                axis: .vertical
            )
            .labelsHidden()
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

            if let error {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("GitHub search syntax, checked against the items Gitwall already has. Repeating a qualifier means AND, a comma inside one means OR, a leading minus excludes. A query that cannot be read matches nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Qualifiers and examples") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: SearchQuery.supportedQualifiers.map { "\($0):" }.joined(separator: "  "))
                        .font(.system(.caption, design: .monospaced))
                    Text("@me stands for the account you signed in with. is: and type: take pr, issue, draft or open. Values with spaces go in quotes. A bare word matches the title, the repository or #number.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(Self.examples, id: \.0) { example, explanation in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: example).font(.system(.caption, design: .monospaced))
                            Text(explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    private static let examples: [(String, String)] = [
        ("assignee:@me assignee:franta-dxh,lumir-sokol,tom-gilsky", "Assigned to me and to at least one of the three"),
        ("is:issue -label:blocked label:bug,security", "Issues labelled bug or security, never blocked"),
        (#"milestone:"Q4 2026" -author:renovate"#, "In that milestone, not opened by renovate"),
    ]
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
