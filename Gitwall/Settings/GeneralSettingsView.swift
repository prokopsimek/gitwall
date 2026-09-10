import GitwallCore
import SwiftUI
import UserNotifications

struct GeneralSettingsView: View {
    @Bindable var environment: AppEnvironment
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Sync") {
                Picker("Refresh every", selection: Binding(
                    get: { environment.config.settings.refreshIntervalMinutes },
                    set: { minutes in
                        var settings = environment.config.settings
                        settings.refreshIntervalMinutes = minutes
                        environment.updateSettings(settings)
                    }
                )) {
                    ForEach(AppSettings.refreshIntervalChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
                LabeledContent("Last sync") {
                    if let fetchedAt = environment.snapshot?.fetchedAt {
                        Text(fetchedAt, style: .relative) + Text(" ago")
                    } else {
                        Text("Never")
                    }
                }
                Button(environment.isRefreshing ? "Refreshing…" : "Refresh Now") {
                    Task { await environment.refresh() }
                }
                .disabled(environment.isRefreshing)
            }

            Section("Behaviour") {
                Toggle("Launch at login", isOn: $environment.launchesAtLogin)
                if environment.launchAtLoginRequiresApproval {
                    Text("Approval required in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show icon in the Dock", isOn: $environment.showsDockIcon)
            }

            Section("Notifications") {
                LabeledContent("Permission") {
                    Text(permissionDescription)
                }
                if environment.notifications.authorizationStatus == .denied {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else if environment.notifications.authorizationStatus == .notDetermined {
                    Button("Allow Notifications") {
                        Task { await environment.notifications.requestAuthorizationIfNeeded() }
                    }
                }
                Text("Which events notify you is configured per preset.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Shared container") {
                    Text(environment.containerAvailable ? "Available" : "Missing")
                        .foregroundStyle(environment.containerAvailable ? Color.primary : Color.red)
                }
                ForEach(environment.config.accounts) { account in
                    LabeledContent(account.displayName) {
                        if let status = environment.snapshot?.accountStatus[account.id] {
                            Text(status.state == .ok ? "OK" : (status.message ?? status.state.rawValue))
                                .foregroundStyle(status.state == .ok ? Color.primary : Color.orange)
                        } else {
                            Text("Not synced yet")
                        }
                    }
                }
                if let error = environment.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Version") { Text(Bundle.main.versionDescription) }
                Button("Reset All Data…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Remove all accounts, tokens, presets and cached data?", isPresented: $confirmReset) {
                        Button("Reset Everything", role: .destructive) { environment.resetAllData() }
                    }
            }
        }
        .formStyle(.grouped)
        .task { await environment.notifications.refreshAuthorizationStatus() }
    }

    private var permissionDescription: String {
        switch environment.notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not requested yet"
        @unknown default: "Unknown"
        }
    }
}
