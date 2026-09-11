import AppKit
import GitwallAuth
import GitwallCore
import GitwallGitHub
import GitwallGitLab
import Observation
import OSLog
import ServiceManagement
import WidgetKit

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "app")

enum SettingsTab: String, CaseIterable, Identifiable {
    case accounts, repositories, presets, general, about
    var id: String { rawValue }
}

/// App-wide state shared by the status item, popover and settings. Main-actor bound.
@MainActor
@Observable
final class AppEnvironment {
    // MARK: State

    private(set) var config: AppConfig = .empty
    private(set) var snapshot: Snapshot?
    private(set) var previousSnapshot: Snapshot?
    private(set) var isRefreshing = false
    /// Set when a refresh was requested while one was running; the running one loops once more.
    @ObservationIgnored private var refreshPending = false
    private(set) var lastError: String?
    var selectedPresetID: UUID?
    /// Item ids that appeared in the last sync, for the "new" dot in the popover.
    private(set) var newItemIDs: Set<String> = []
    /// Credential expiry per account; `nil` value means the credential has no expiry. See `reloadTokenExpiries`.
    private(set) var tokenExpiries: [UUID: Date?] = [:]

    let container: URL?
    let configStore: ConfigStore?
    let snapshotStore: SnapshotStore?
    /// `--debug-demo`: fictional accounts and items from `DemoData`, kept in memory only (screenshots, UI work).
    let isDemo: Bool
    /// `--debug-fresh` and the app test host: a throwaway installation, which must not touch login items either.
    private let isSandbox: Bool
    let tokenStore: any TokenStore
    let providers: [ProviderKind: any GitProvider]
    let notifications = NotificationDispatcher()

    @ObservationIgnored var onShowPopover: (() -> Void)?
    @ObservationIgnored var onOpenSettings: ((SettingsTab) -> Void)?
    @ObservationIgnored var onOpenMainWindow: ((UUID?) -> Void)?
    @ObservationIgnored var onShowWidgetHelp: (() -> Void)?
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var syncEngine: SyncEngine?
    @ObservationIgnored private let avatars: AvatarDownloader?
    @ObservationIgnored private let defaults: UserDefaults

    /// `sandbox` points the config, snapshot and tokens at a throwaway directory so a test run cannot touch
    /// the real installation's accounts (`--debug-fresh`).
    init(defaults: UserDefaults = .standard, tokenStore: (any TokenStore)? = nil, demo: Bool = false, sandbox: URL? = nil) {
        self.defaults = defaults
        self.tokenStore = tokenStore ?? (sandbox == nil ? KeychainTokenStore() : InMemoryTokenStore())
        self.providers = [.github: GitHubProvider(), .gitlab: GitLabProvider()]
        isDemo = demo
        isSandbox = sandbox != nil
        container = demo ? nil : (sandbox ?? AppGroup.containerURL())
        if let sandbox { try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true) }
        if demo {
            configStore = nil
            snapshotStore = nil
            avatars = nil
            log.info("Demo mode: in-memory sample data, no App Group or Keychain access")
        } else if let container {
            configStore = ConfigStore(directoryURL: container)
            snapshotStore = SnapshotStore(directoryURL: container)
            avatars = AvatarDownloader(container: container)
            log.info("App Group container: \(container.path, privacy: .public)")
        } else {
            configStore = nil
            snapshotStore = nil
            avatars = nil
            log.error("App Group container unavailable for \(AppGroup.identifier, privacy: .public)")
        }
    }

    var containerAvailable: Bool { container != nil || isDemo }

    // MARK: Lifecycle

    func start() {
        if isDemo {
            config = DemoData.config
            snapshot = DemoData.snapshot()
            selectedPresetID = config.presets.first?.id
            applyActivationPolicy()
            return
        }
        do {
            config = try configStore?.load() ?? .empty
        } catch {
            log.error("Config unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            lastError = "Configuration could not be read: \(error.localizedDescription)"
        }
        seedDefaultPresetsIfNeeded()
        registerAtLoginOnFirstLaunch()
        snapshot = try? snapshotStore?.load()
        previousSnapshot = try? snapshotStore?.loadPrevious()
        reloadTokenExpiries()
        if selectedPresetID == nil { selectedPresetID = config.presets.first?.id }
        if let configStore, let snapshotStore {
            // The reader refreshes OAuth tokens behind the sync engine's back, so a signed-in account never
            // asks the user to sign in again just because its access token expired.
            let refresher = TokenRefresher(store: tokenStore, flows: { account in
                guard let client = OAuthClients.client(for: account), client.kind == .gitlab else { return nil }
                return GitLabPKCEFlow(client: client)
            })
            syncEngine = SyncEngine(
                providers: providers,
                tokens: RefreshingTokenReader(refresher: refresher, accounts: { (try? configStore.load().accounts) ?? [] }),
                configStore: configStore,
                snapshotStore: snapshotStore
            )
        }
        applyActivationPolicy()
        scheduleRefreshLoop()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    var needsOnboarding: Bool { config.accounts.isEmpty }

    /// Accounts added before per-account presets existed get theirs once. Presets deleted afterwards stay deleted.
    private func seedDefaultPresetsIfNeeded() {
        let seeded = config.seedingDefaultPresets { [providers] kind in
            providers[kind]?.capabilities.pullRequestTerm ?? "Pull request"
        }
        guard seeded != config else { return }
        let count = config.accounts.filter { $0.defaultPresetsCreated != true }.count
        do {
            try persist(seeded, refresh: false)
            log.info("Created default presets for \(count) existing accounts")
        } catch {
            log.error("Could not save the default presets: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Product decision: a menu bar agent is only useful when it is running, so a fresh installation starts with
    /// Launch at login on. `AppConfig.shouldRegisterAtLogin` keeps it to the first launch; a failed registration
    /// leaves the flag unset so the next launch tries again. Users switch it off in General.
    private func registerAtLoginOnFirstLaunch() {
        guard !isSandbox, config.shouldRegisterAtLogin else { return }
        if SMAppService.mainApp.status == .notRegistered {
            do {
                try SMAppService.mainApp.register()
                log.info("Launch at login switched on for the fresh installation")
            } catch {
                log.error("Could not switch Launch at login on: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        var updated = config
        updated.settings.launchAtLoginConfigured = true
        try? persist(updated, refresh: false)
    }

    private func scheduleRefreshLoop() {
        refreshLoop?.cancel()
        let interval = config.settings.refreshInterval
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    // MARK: Sync

    func refresh() async {
        guard let syncEngine else { return }
        if isRefreshing {
            refreshPending = true
            return
        }
        guard !config.accounts.isEmpty else {
            // Nothing to fetch, but keep the widget consistent with an empty configuration.
            if snapshot == nil, let snapshotStore {
                let empty = Snapshot(fetchedAt: Date(), items: [])
                try? snapshotStore.save(empty)
                snapshot = empty
                WidgetCenter.shared.reloadAllTimelines()
            }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshPending {
                refreshPending = false
                Task { await self.refresh() }
            }
        }
        do {
            let result = try await syncEngine.sync()
            previousSnapshot = result.previous
            snapshot = result.snapshot
            lastError = nil
            // A snapshot written before any account was synced is not a baseline: the first real sync must not
            // flag every item as new or fire a burst of notifications.
            let baseline = (result.previous?.accountStatus.isEmpty ?? true) ? nil : result.previous
            let changes = SnapshotDiff.changes(from: baseline, to: result.snapshot, accounts: config.accounts)
            newItemIDs = Set(changes.filter { $0.event == .newItem }.map(\.item.id))
            log.info("Sync finished with \(result.snapshot.items.count) items, \(changes.count) changes")

            reloadTokenExpiries()
            await avatars?.download(for: result.snapshot.items)
            WidgetCenter.shared.reloadAllTimelines()

            let routed = SnapshotDiff.notifications(
                for: changes, presets: config.presets, accounts: config.accounts,
                previous: baseline, now: Date()
            )
            await notifications.deliver(routed, capabilities: providers)
        } catch {
            lastError = error.localizedDescription
            log.error("Sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Derived data

    var selectedPreset: Preset? {
        config.preset(id: selectedPresetID ?? UUID()) ?? config.presets.first
    }

    func items(for preset: Preset, now: Date = Date()) -> [WorkItem] {
        guard let snapshot else { return [] }
        return FilterEngine.items(matching: preset, in: snapshot.items, accounts: config.accounts, now: now)
    }

    func count(for preset: Preset) -> Int {
        items(for: preset).count
    }

    /// Text shown next to the menu bar icon.
    var menuBarBadge: String {
        guard let preset = config.presets.first(where: \.showCountInMenuBar) else { return "" }
        let count = count(for: preset)
        return count == 0 ? "" : String(count)
    }

    var accountsNeedingAttention: [(Account, FetchStatus)] {
        config.accounts.compactMap { account in
            if let status = snapshot?.accountStatus[account.id], status.state != .ok {
                return (account, status)
            }
            // A working token that runs out next week is worth a quiet heads-up before it breaks the sync.
            if let expiresAt = expiry(for: account), expiresAt.timeIntervalSinceNow < 7 * 24 * 3600 {
                let when = expiresAt.formatted(date: .abbreviated, time: .omitted)
                let message = expiresAt.timeIntervalSinceNow <= 0 ? "The token expired on \(when)." : "The token expires on \(when)."
                return (account, FetchStatus(state: .needsReauth, lastSuccessAt: snapshot?.accountStatus[account.id]?.lastSuccessAt, message: message))
            }
            return nil
        }
    }

    /// Expiry of the stored credential, when it has one. Read from a cache: `accountsNeedingAttention` is
    /// evaluated on every SwiftUI render and the Keychain is too slow to touch that often.
    func expiry(for account: Account) -> Date? {
        tokenExpiries[account.id] ?? nil
    }

    /// Rereads every credential's expiry. Called at start and whenever a credential changes.
    func reloadTokenExpiries() {
        var expiries: [UUID: Date?] = [:]
        for account in config.accounts {
            expiries[account.id] = (try? tokenStore.token(for: account.id))?.expiresAt
        }
        tokenExpiries = expiries
    }

    /// OAuth accounts can be repaired by signing in again; token accounts need a new token pasted in.
    func usesOAuth(_ account: Account) -> Bool {
        if case .oauth = account.authMethod { return true }
        return false
    }

    func provider(for account: Account) -> (any GitProvider)? {
        providers[account.kind]
    }

    // MARK: Accounts

    @discardableResult
    func addAccount(kind: ProviderKind, baseURL: URL, credential: StoredToken, authMethod: AuthMethod = .personalAccessToken) async throws -> Account {
        guard let provider = providers[kind] else { throw AppError.unsupportedProvider }
        let me = try await provider.verify(baseURL: baseURL, token: credential.accessToken)
        var account = Account(
            kind: kind,
            baseURL: baseURL,
            displayName: baseURL.host.map { host in host == "github.com" ? "GitHub" : host } ?? kind.rawValue,
            me: me,
            authMethod: authMethod
        )
        account.displayName += " (\(me.login))"
        try tokenStore.set(await stamped(credential, provider: provider, baseURL: baseURL), for: account.id)
        // The account arrives with its own three presets (assigned pull requests, assigned issues, reviews waiting).
        let updated = config.adding(account, pullRequestTerm: provider.capabilities.pullRequestTerm)
        try persist(updated)
        reloadTokenExpiries()
        if selectedPresetID == nil { selectedPresetID = updated.presets.first?.id }
        // Hand back the stored account, which carries the preset marker.
        let stored = updated.account(id: account.id) ?? account
        // The permission prompt blocks until the user answers; never await it on the account flow.
        Task { await notifications.requestAuthorizationIfNeeded() }
        return stored
    }

    func updateAccount(_ account: Account) {
        var updated = config
        guard let index = updated.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        updated.accounts[index] = account
        try? persist(updated)
    }

    func removeAccount(_ account: Account) {
        let updated = config.removing(accountID: account.id)
        if let selectedPresetID, updated.preset(id: selectedPresetID) == nil {
            self.selectedPresetID = updated.presets.first?.id
        }
        try? tokenStore.removeToken(for: account.id)
        try? persist(updated)
        reloadTokenExpiries()
    }

    /// "Add Default Presets" from the account menu: restores whichever of the three are missing.
    func addDefaultPresets(for account: Account) {
        guard let provider = providers[account.kind] else { return }
        let updated = config.addingDefaultPresets(for: account.id, pullRequestTerm: provider.capabilities.pullRequestTerm)
        guard updated != config else { return }
        try? persist(updated, refresh: false)
    }

    /// Replaces the credential of an existing account, keeping its id so presets and widgets stay attached.
    func replaceCredential(for account: Account, credential: StoredToken, authMethod: AuthMethod? = nil) async throws {
        guard let provider = providers[account.kind] else { throw AppError.unsupportedProvider }
        let me = try await provider.verify(baseURL: account.baseURL, token: credential.accessToken)
        var updatedAccount = account
        updatedAccount.me = me
        if let authMethod { updatedAccount.authMethod = authMethod }
        try tokenStore.set(await stamped(credential, provider: provider, baseURL: account.baseURL), for: account.id)
        updateAccount(updatedAccount)
        reloadTokenExpiries()
        Task { await refresh() }
    }

    /// Adds the token's expiry date when the provider knows one, so Settings can warn before it stops working.
    /// OAuth credentials already carry their own expiry from the token response.
    private func stamped(_ credential: StoredToken, provider: any GitProvider, baseURL: URL) async -> StoredToken {
        guard credential.expiresAt == nil else { return credential }
        var stamped = credential
        stamped.expiresAt = await provider.tokenExpiry(baseURL: baseURL, token: credential.accessToken)
        return stamped
    }

    // MARK: Presets

    func addPreset(_ preset: Preset) {
        var updated = config
        updated.presets.append(preset)
        try? persist(updated)
        selectedPresetID = preset.id
    }

    func updatePreset(_ preset: Preset) {
        var updated = config
        guard let index = updated.presets.firstIndex(where: { $0.id == preset.id }) else { return }
        updated.presets[index] = preset
        if preset.showCountInMenuBar {
            for other in updated.presets.indices where updated.presets[other].id != preset.id {
                updated.presets[other].showCountInMenuBar = false
            }
        }
        try? persist(updated, refresh: false)
    }

    func removePreset(_ preset: Preset) {
        var updated = config
        updated.presets.removeAll { $0.id == preset.id }
        try? persist(updated, refresh: false)
        if selectedPresetID == preset.id { selectedPresetID = updated.presets.first?.id }
    }

    func movePresets(from source: IndexSet, to destination: Int) {
        var updated = config
        updated.presets.move(fromOffsets: source, toOffset: destination)
        try? persist(updated, refresh: false)
    }

    // MARK: Settings

    func updateSettings(_ settings: AppSettings) {
        var updated = config
        let intervalChanged = updated.settings.refreshIntervalMinutes != settings.refreshIntervalMinutes
        updated.settings = settings
        try? persist(updated, refresh: false)
        if intervalChanged { scheduleRefreshLoop() }
    }

    func resetAllData() {
        for account in config.accounts { try? tokenStore.removeToken(for: account.id) }
        try? persist(.empty, refresh: false)
        if let snapshotStore {
            try? FileManager.default.removeItem(at: snapshotStore.currentURL)
            try? FileManager.default.removeItem(at: snapshotStore.previousURL)
        }
        if let container {
            try? FileManager.default.removeItem(at: AvatarFiles.directory(in: container))
        }
        snapshot = nil
        previousSnapshot = nil
        selectedPresetID = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func persist(_ updated: AppConfig, refresh: Bool = true) throws {
        if isDemo {
            config = updated
            return
        }
        guard let configStore else { throw AppError.containerUnavailable }
        try configStore.save(updated)
        config = updated
        WidgetCenter.shared.reloadAllTimelines()
        if refresh {
            Task { await self.refresh() }
        }
    }

    // MARK: Deep links & windows

    func handle(_ link: DeepLink) {
        switch link {
        case .item(let id):
            open(itemID: id)
        case .view(let id):
            openMainWindow(presetID: id)
        case .refresh:
            Task { await refresh() }
        case .settings(let tab):
            openSettings(tab.flatMap(SettingsTab.init(rawValue:)) ?? .accounts)
        }
    }

    func open(itemID: String) {
        guard let item = snapshot?.items.first(where: { $0.id == itemID })
            ?? previousSnapshot?.items.first(where: { $0.id == itemID }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func showPopover() {
        onShowPopover?()
    }

    func openMainWindow(presetID: UUID? = nil) {
        onOpenMainWindow?(presetID)
    }

    func showWidgetHelp() {
        onShowWidgetHelp?()
    }

    /// What a list for `preset` should show right now. Shared by the popover and the main window.
    func listState(for preset: Preset?) -> ListState {
        guard containerAvailable else { return .empty(.containerUnavailable) }
        guard !needsOnboarding else { return .empty(.noAccounts) }
        guard let preset else { return .empty(.noPresets) }
        let items = items(for: preset)
        if !items.isEmpty { return .items(items) }
        if snapshot == nil || isRefreshing { return .empty(.loading) }
        if config.accounts.allSatisfy(\.sources.isEmpty) { return .empty(.noRepositories) }
        return .empty(.nothingMatches(presetName: preset.name))
    }

    func openSettings(_ tab: SettingsTab = .accounts) {
        onOpenSettings?(tab)
    }

    func avatar(for url: URL?) -> NSImage? {
        guard let url, let container else { return nil }
        return NSImage(contentsOf: AvatarFiles.fileURL(for: url, in: container))
    }

    // MARK: Preferences stored outside the shared config

    private enum Keys {
        static let showsDockIcon = "showsDockIcon"
    }

    /// On by default; users who prefer a pure menu bar agent switch it off in General.
    var showsDockIcon: Bool {
        get { defaults.object(forKey: Keys.showsDockIcon) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.showsDockIcon)
            applyActivationPolicy()
        }
    }

    /// The app is a regular app in Info.plist (Dock icon on by default) and drops to an accessory when the
    /// user hides the Dock icon; going the other way at runtime leaves the Dock with a generic icon.
    func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
            // Known AppKit quirk: after .accessory -> .regular the main menu stays inactive until re-activation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    var launchAtLoginRequiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}

enum ListState: Equatable {
    case items([WorkItem])
    case empty(EmptyStateKind)
}

enum AppError: LocalizedError {
    case unsupportedProvider
    case containerUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: "This provider is not available yet."
        case .containerUnavailable: "The shared container is unavailable. Reinstall the app."
        }
    }
}
