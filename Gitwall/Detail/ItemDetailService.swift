import Foundation
import GitwallAuth
import GitwallCore
import Observation
import OSLog

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "detail")

/// App-wide part of Detail, shared by every window that shows it: the fetches and the one cache of what they
/// returned, and when each item was last opened (`seen.json`, see ``SeenStore``). Per-window state is in
/// ``DetailModel``.
@MainActor
@Observable
final class ItemDetailService {
    /// Item id → last opened in Detail. Sample items live here only; they never reach the store.
    private(set) var seen: [String: Date] = [:]

    @ObservationIgnored private let fetcher: DetailFetcher
    @ObservationIgnored private let seenStore: SeenStore?
    /// On the main actor, so an item fetched before shows without waiting for the fetcher.
    @ObservationIgnored private var cache = DetailCache()
    /// Bumped by ``forget(accountID:)``, so a fetch that started with the old credential is not kept.
    @ObservationIgnored private var generations: [UUID: Int] = [:]

    /// `container` is nil in `--debug-demo`, which keeps everything in memory.
    init(providers: [ProviderKind: any GitProvider], tokens: any TokenStore, container: URL?) {
        fetcher = DetailFetcher(providers: providers, tokens: tokens.asTokenReading())
        seenStore = container.map(SeenStore.init(directoryURL:))
        if let seenStore {
            Task { [weak self] in
                let stored = await seenStore.load()
                self?.seen.merge(stored) { inMemory, _ in inMemory }
            }
        }
    }

    func lastSeen(_ itemID: String) -> Date? { seen[itemID] }

    /// The dot in lists: moved since it was last opened here.
    func hasChanged(_ item: WorkItem) -> Bool { WhatsNew.hasChanged(item, lastSeenAt: seen[item.id]) }

    /// `persist` is false for sample content, which must not reach the App Group.
    func markSeen(_ item: WorkItem, at date: Date, liveItemIDs: Set<String>, persist: Bool) {
        seen[item.id] = date
        guard persist, let seenStore else { return }
        Task {
            do {
                try await seenStore.markSeen(item.id, at: date, keeping: liveItemIDs)
            } catch {
                log.error("Could not save when an item was opened: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cachedDetail(for item: WorkItem) -> ItemDetail? { cache.detail(for: item) }

    /// The cached detail while the item keeps its state, else a fetch. `forceRefresh` (Try Again) always fetches.
    func load(_ item: WorkItem, account: Account, forceRefresh: Bool) async -> DetailLoad {
        if !forceRefresh, let cached = cache.detail(for: item) { return .loaded(cached) }
        let generation = generations[account.id, default: 0]
        let load = await fetcher.detail(for: item, account: account)
        if case .loaded(let detail) = load, generations[account.id, default: 0] == generation {
            cache.store(detail, accountID: account.id)
        }
        return load
    }

    /// The account's credential changed or it was removed: what was fetched with the old one, a missing permission
    /// too, is fetched again.
    func forget(accountID: UUID) {
        cache.forget(accountID: accountID)
        generations[accountID, default: 0] += 1
    }
}
