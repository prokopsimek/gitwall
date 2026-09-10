import AppKit
import GitwallAuth
import GitwallCore
import GitwallGitHub
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

    let container: URL?
    let configStore: ConfigStore?
    let snapshotStore: SnapshotStore?
    let tokenStore: any TokenStore
    let providers: [ProviderKind: any GitProvider]
    let notifications = NotificationDispatcher()

    @ObservationIgnored var onShowPopover: (() -> Void)?
    @ObservationIgnored var onOpenSettings: ((SettingsTab) -> Void)?
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var syncEngine: SyncEngine?
    @ObservationIgnored private let avatars: AvatarDownloader?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, tokenStore: (any TokenStore)? = nil) {
        self.defaults = defaults
        self.tokenStore = tokenStore ?? KeychainTokenStore()
        self.providers = [.github: GitHubProvider()]
        container = AppGroup.containerURL()
        if let container {
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

    var containerAvailable: Bool { container != nil }

    // MARK: Lifecycle

    func start() {
        do {
            config = try configStore?.load() ?? .empty
        } catch {
            log.error("Config unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            lastError = "Configuration could not be read: \(error.localizedDescription)"
        }
        snapshot = try? snapshotStore?.load()
        previousSnapshot = try? snapshotStore?.loadPrevious()
        if selectedPresetID == nil { selectedPresetID = config.presets.first?.id }
        if let configStore, let snapshotStore {
            syncEngine = SyncEngine(
                providers: providers,
                tokens: TokenReader(store: tokenStore),
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
            guard let status = snapshot?.accountStatus[account.id], status.state != .ok else { return nil }
            return (account, status)
        }
    }

    func provider(for account: Account) -> (any GitProvider)? {
        providers[account.kind]
    }

    // MARK: Accounts

    @discardableResult
    func addAccount(kind: ProviderKind, baseURL: URL, token: String) async throws -> Account {
        guard let provider = providers[kind] else { throw AppError.unsupportedProvider }
        let me = try await provider.verify(baseURL: baseURL, token: token)
        var account = Account(
            kind: kind,
            baseURL: baseURL,
            displayName: baseURL.host.map { host in host == "github.com" ? "GitHub" : host } ?? kind.rawValue,
            me: me
        )
        account.displayName += " (\(me.login))"
        try tokenStore.set(StoredToken(accessToken: token, obtainedAt: Date()), for: account.id)
        var updated = config
        updated.accounts.append(account)
        if updated.presets.isEmpty {
            updated.presets = Preset.defaults()
        }
        let isFirstAccount = config.accounts.isEmpty
        try persist(updated)
        if selectedPresetID == nil { selectedPresetID = updated.presets.first?.id }
        // The permission prompt blocks until the user answers; never await it on the account flow.
        Task { await notifications.requestAuthorizationIfNeeded() }
        if isFirstAccount, SMAppService.mainApp.status == .notRegistered {
            // Product decision: a menu bar agent is only useful when it is running. Users can switch it off in General.
            try? SMAppService.mainApp.register()
        }
        return account
    }

    func updateAccount(_ account: Account) {
        var updated = config
        guard let index = updated.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        updated.accounts[index] = account
        try? persist(updated)
    }

    func removeAccount(_ account: Account) {
        var updated = config
        updated.accounts.removeAll { $0.id == account.id }
        for index in updated.presets.indices {
            updated.presets[index].scopes.removeAll { $0.accountID == account.id }
        }
        try? tokenStore.removeToken(for: account.id)
        try? persist(updated)
    }

    func replaceToken(for account: Account, token: String) async throws {
        guard let provider = providers[account.kind] else { throw AppError.unsupportedProvider }
        let me = try await provider.verify(baseURL: account.baseURL, token: token)
        var updatedAccount = account
        updatedAccount.me = me
        try tokenStore.set(StoredToken(accessToken: token, obtainedAt: Date()), for: account.id)
        updateAccount(updatedAccount)
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
            if config.preset(id: id) != nil { selectedPresetID = id }
            showPopover()
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

    func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
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
