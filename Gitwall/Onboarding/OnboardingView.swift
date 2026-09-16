import GitwallCore
import SwiftUI

/// First-run walkthrough: connect an account, pick repositories, review the default presets, decide about
/// notifications and startup, and learn how to place a widget. Every step after the account can be skipped.
struct OnboardingView: View {
    @Bindable var environment: AppEnvironment
    let finish: () -> Void

    @State private var step: OnboardingStep

    init(environment: AppEnvironment, initialStep: OnboardingStep = .welcome, finish: @escaping () -> Void) {
        self.environment = environment
        self.finish = finish
        _step = State(initialValue: initialStep)
    }

    @State private var showingAddAccount = false
    @State private var repositoriesState = SettingsState()

    var body: some View {
        HStack(spacing: 0) {
            steps
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                buttons
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .sheet(isPresented: $showingAddAccount) {
            AddAccountSheet(environment: environment) { _ in
                // Repositories are the natural next question once an account exists.
                step = .repositories
            }
        }
    }

    // MARK: - Chrome

    private var steps: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Setup")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            ForEach(OnboardingStep.allCases) { item in
                HStack(spacing: 8) {
                    Image(systemName: isDone(item) ? "checkmark.circle.fill" : item.symbol)
                        .foregroundStyle(isDone(item) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 20)
                    Text(item.title)
                        .foregroundStyle(item == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(item == step ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { if reachable(item) { step = item } }
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .frame(width: 220)
        .background(.quaternary.opacity(0.25))
    }

    private var buttons: some View {
        HStack {
            if let previous = step.previous {
                Button("Back") { step = previous }
            }
            Spacer()
            if step != .widget, step != .account {
                Button("Skip") { finish() }
                    .buttonStyle(.link)
            }
            if let next = step.next {
                Button("Continue") { step = next }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!step.canContinue(with: environment.config))
            } else {
                Button("Finish") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func isDone(_ item: OnboardingStep) -> Bool {
        guard let index = OnboardingStep.allCases.firstIndex(of: item),
              let current = OnboardingStep.allCases.firstIndex(of: step) else { return false }
        return index < current
    }

    private func reachable(_ item: OnboardingStep) -> Bool {
        guard let index = OnboardingStep.allCases.firstIndex(of: item),
              let current = OnboardingStep.allCases.firstIndex(of: step) else { return false }
        // Going back is always fine; going forward needs the account in place.
        return index <= current || !environment.config.accounts.isEmpty
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .account: account
        case .repositories: repositories
        case .presets: presets
        case .notifications: notifications
        case .startup: startup
        case .widget: widget
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
            header("Pull requests and issues, one glance away",
                   "Gitwall gathers open pull requests, merge requests and issues from the GitHub and GitLab repositories you choose, and keeps them in your menu bar and on your desktop.")
            VStack(alignment: .leading, spacing: 10) {
                bullet("person.2", "Works with github.com, GitLab.com, GitHub Enterprise Server and self-managed GitLab.")
                bullet("slider.horizontal.3", "Named views you define: any mix of accounts, repositories, pull requests and issues, with filters.")
                bullet("square.grid.2x2", "Desktop widgets in four sizes, each showing the view you pick.")
                bullet("lock", "No server, no analytics. Tokens stay in your Keychain.")
            }
        }
        .padding(28)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Connect an account",
                   "Sign in with GitHub or GitLab, or paste a personal access token. You can add more accounts later in Settings.")
            if environment.config.accounts.isEmpty {
                Button {
                    showingAddAccount = true
                } label: {
                    Label("Add Account…", systemImage: "plus")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                if environment.canShowSampleData {
                    Button("Look around with sample data") { environment.enterSampleData() }
                        .buttonStyle(.link)
                    Text("Fictional pull requests and issues, so you can see what Gitwall does before connecting anything. Nothing is saved and no account is needed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if environment.isSampleData {
                Label("Showing sample data", systemImage: "wand.and.stars")
                    .font(.headline)
                Button("Stop showing sample data") { environment.leaveSampleData() }
            } else {
                ForEach(environment.config.accounts) { account in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName).font(.headline)
                            Text(account.baseURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                Button("Add another account…") { showingAddAccount = true }
            }
        }
        .padding(28)
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Choose repositories",
                   "Tick the repositories, organizations or groups Gitwall should watch. Whole organizations and groups keep up with new repositories on their own.")
                .padding([.horizontal, .top], 28)
            RepositoriesSettingsView(environment: environment, state: repositoriesState)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Your views",
                   "Each account gets three presets: pull requests and issues assigned to you, and reviews waiting for you. All open shows everything in one place. Each widget shows one preset; change the filters or add your own in Settings › Presets.")
            ForEach(environment.config.presets) { preset in
                HStack(spacing: 10) {
                    Image(systemName: preset.icon).foregroundStyle(.tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).font(.headline)
                        Text(description(of: preset)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(environment.count(for: preset))")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Button("Edit presets…") { environment.openSettings(.presets) }
                .buttonStyle(.link)
        }
        .padding(28)
    }

    private func description(of preset: Preset) -> String {
        var parts: [String] = []
        if preset.kinds == [.pullRequest] { parts.append("pull requests") }
        else if preset.kinds == [.issue] { parts.append("issues") }
        else { parts.append("pull requests and issues") }
        if preset.filter.relations.contains(.authoredByMe) { parts.append("you opened") }
        if preset.filter.relations.contains(.reviewRequestedFromMe) { parts.append("waiting for your review") }
        if preset.filter.relations.contains(.assignedToMe) { parts.append("assigned to you") }
        return parts.joined(separator: ", ").capitalizedFirst
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Notifications",
                   "Gitwall can tell you when something changes in your views. Everything is on to begin with; switch off what you do not need. Each preset keeps its own choice in Settings › Presets.")
            Button {
                Task { await environment.notifications.requestAuthorizationIfNeeded() }
            } label: {
                Label("Allow notifications", systemImage: "bell.badge")
            }
            .disabled(environment.notifications.authorizationStatus == .authorized)
            if environment.notifications.authorizationStatus == .denied {
                Text("Notifications are switched off for Gitwall in System Settings › Notifications.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            ForEach(NotificationEvent.allCases, id: \.self) { event in
                Toggle(title(of: event), isOn: binding(for: event))
            }
            Text("Applies to every preset. Fine-tune per preset later.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private func title(of event: NotificationEvent) -> String {
        switch event {
        case .newItem: "New item"
        case .reviewRequested: "Review requested from me"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .ciFailed: "Checks failed"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    /// One switch for all presets: on when every preset wants the event.
    private func binding(for event: NotificationEvent) -> Binding<Bool> {
        Binding(
            get: { !environment.config.presets.isEmpty && environment.config.presets.allSatisfy { $0.notifications.contains(event) } },
            set: { on in
                for preset in environment.config.presets {
                    var updated = preset
                    if on { updated.notifications.insert(event) } else { updated.notifications.remove(event) }
                    environment.updatePreset(updated)
                }
            }
        )
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Startup",
                   "Gitwall lives in the menu bar and refreshes in the background, so it is most useful when it is already running.")
            Toggle("Launch at login", isOn: $environment.launchesAtLogin)
            if environment.launchAtLoginRequiresApproval {
                Text("Approval required in System Settings › General › Login Items.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Show icon in the Dock", isOn: $environment.showsDockIcon)
            Text("Without the Dock icon Gitwall is a pure menu bar app. You can change both later in Settings › General.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
    }

    private var widget: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Add a widget", "The last step happens on your desktop, so here is how.")
            AddWidgetSteps()
        }
        .padding(28)
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
