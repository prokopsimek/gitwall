import Foundation
import GitwallAuth
import GitwallCore
import Observation
import OSLog

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "detail")

/// App-wide part of Detail, shared by every window that shows it: the fetches and their cache, and when each item was
/// last opened (`seen.json`, see ``SeenStore``). Per-window state is in ``DetailModel``.
@MainActor
@Observable
final class ItemDetailService {
    /// Item id → last opened in Detail. Sample items live here only; they never reach the store.
    private(set) var seen: [String: Date] = [:]

    @ObservationIgnored private let fetcher: DetailFetcher
    @ObservationIgnored private let seenStore: SeenStore?
    /// A main-actor copy of the recent details, so a cached item shows without waiting a frame for the actor.
    @ObservationIgnored private var recent: [String: ItemDetail] = [:]
    @ObservationIgnored private var recentOrder: [String] = []
    private static let recentLimit = 100

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

    func cachedDetail(for item: WorkItem) -> ItemDetail? {
        guard let detail = recent[item.id], detail.itemUpdatedAt == item.updatedAt else { return nil }
        return detail
    }

    func load(_ item: WorkItem, account: Account, forceRefresh: Bool) async -> DetailLoad {
        let load = await fetcher.detail(for: item, account: account, forceRefresh: forceRefresh)
        if case .loaded(let detail) = load { remember(detail) }
        return load
    }

    private func remember(_ detail: ItemDetail) {
        recent[detail.itemID] = detail
        recentOrder.removeAll { $0 == detail.itemID }
        recentOrder.append(detail.itemID)
        while recentOrder.count > Self.recentLimit { recent[recentOrder.removeFirst()] = nil }
    }
}
