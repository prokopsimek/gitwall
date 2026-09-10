import SwiftUI

struct SettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var state: SettingsState

    var body: some View {
        TabView(selection: $state.tab) {
            AccountsSettingsView(environment: environment, state: state)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(SettingsTab.accounts)
            RepositoriesSettingsView(environment: environment, state: state)
                .tabItem { Label("Repositories", systemImage: "folder") }
                .tag(SettingsTab.repositories)
            PresetsSettingsView(environment: environment)
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.presets)
            GeneralSettingsView(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

extension Bundle {
    var versionDescription: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
