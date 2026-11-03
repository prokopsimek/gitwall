import AppKit
import GitwallCore
import GitwallUI
import Observation
import SwiftUI

/// Detail in one window: which item is selected, whether the panel shows, and what has been fetched for it. Any
/// window attaches it with ``SwiftUI/View/itemDetailInspector(_:environment:preset:)`` and, for the Item menu,
/// ``ItemWindowController``. Arrowing through a list asks the provider only once the selection rests for
/// ``debounce``; an item already fetched in its current state shows at once.
@MainActor
@Observable
final class DetailModel {
    static let debounce: Duration = .milliseconds(150)

    struct Remote {
        let itemID: String
        let load: DetailLoad
    }

    var isPresented = false {
        didSet { if isPresented, !oldValue { scheduleOpen() } }
    }
    private(set) var selectedItemID: String?
    /// The items of the list on screen, in order, for ↑↓ and for Show Detail without a selection.
    var visibleItemIDs: [String] = []
    private(set) var remote: Remote?
    /// When the selected item was opened before this time: the start of "What's new".
    private(set) var baseline: Date?
    /// Events that arrived while the item was on screen.
    private(set) var highlighted: Set<String> = []

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored private var openedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var service: ItemDetailService { environment.details }

    var selectedItem: WorkItem? { selectedItemID.flatMap(environment.item(id:)) }

    /// The selected item's fetched detail, never another item's.
    var selectedRemote: DetailLoad? {
        guard let remote, remote.itemID == selectedItemID else { return nil }
        return remote.load
    }

    // MARK: Selection

    func select(_ itemID: String?) {
        guard itemID != selectedItemID else { return }
        selectedItemID = itemID
        scheduleOpen()
    }

    /// A click in a list: select and show.
    func show(_ itemID: String) {
        select(itemID)
        isPresented = true
    }

    /// Show Detail (Space, ↩): the selection, or the first item when nothing is selected.
    func present() {
        if selectedItemID == nil || selectedItem == nil, let first = visibleItemIDs.first { select(first) }
        isPresented = true
    }

    func close() { isPresented = false }

    func toggle() { isPresented ? close() : present() }

    /// ↑ and ↓: the previous or next visible item.
    func move(by offset: Int) {
        guard !visibleItemIDs.isEmpty else { return }
        guard let current = selectedItemID, let index = visibleItemIDs.firstIndex(of: current) else {
            select(offset > 0 ? visibleItemIDs.first : visibleItemIDs.last)
            return
        }
        let next = min(max(index + offset, 0), visibleItemIDs.count - 1)
        select(visibleItemIDs[next])
    }

    /// Try Again on a part that failed.
    func reload() {
        guard let item = selectedItem else { return }
        task?.cancel()
        task = Task { [weak self] in await self?.open(item, forceRefresh: true) }
    }

    /// A sync changed the item on screen: fetch it again and mark what arrived meanwhile.
    func selectedItemDidChange() {
        guard isPresented, let item = selectedItem, let openedAt else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await open(item, forceRefresh: false)
            guard case .loaded(let detail)? = selectedRemote, let timeline = try? detail.timeline.get() else { return }
            let me = environment.config.account(id: item.accountID)?.me
            highlighted.formUnion(WhatsNew.events(in: timeline, lastSeenAt: openedAt, me: me).map(\.id))
        }
    }

    private func scheduleOpen() {
        task?.cancel()
        highlighted = []
        openedAt = nil
        guard let item = selectedItem else {
            remote = nil
            return
        }
        baseline = service.lastSeen(item.id)
        if remote?.itemID != item.id {
            remote = service.cachedDetail(for: item).map { Remote(itemID: item.id, load: .loaded($0)) }
        }
        guard isPresented else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.open(item, forceRefresh: false)
        }
    }

    private func open(_ item: WorkItem, forceRefresh: Bool) async {
        let now = Date()
        openedAt = now
        service.markSeen(item, at: now, liveItemIDs: Set(environment.snapshot?.items.map(\.id) ?? []),
                         persist: !environment.usesSampleContent)
        let load: DetailLoad
        if environment.usesSampleContent {
            load = DemoData.detail(for: item).map(DetailLoad.loaded) ?? .unsupported
        } else if let account = environment.config.account(id: item.accountID) {
            load = await service.load(item, account: account, forceRefresh: forceRefresh)
        } else {
            load = .unsupported
        }
        guard !Task.isCancelled, selectedItemID == item.id else { return }
        remote = Remote(itemID: item.id, load: load)
    }

    // MARK: Content

    /// What ``DetailView`` shows for `item`, opened from `preset`.
    func content(for item: WorkItem, preset: Preset?) -> DetailContent {
        let account = environment.config.account(id: item.accountID)
        let me = account?.me
        let capabilities = account.flatMap(environment.provider(for:))?.capabilities
        let remote = selectedRemote
        let detail: ItemDetail? = if case .loaded(let detail)? = remote { detail } else { nil }
        let timeline = (try? detail?.timeline.get()) ?? []
        return DetailContent(
            item: item,
            authorAvatar: environment.avatar(for: item.author.avatarURL).map { Image(nsImage: $0) },
            presetName: preset?.name,
            reasons: FilterEngine.explain(item, query: preset?.filter.query, me: me),
            nextStep: NextStep.suggest(for: item, detail: detail, me: me, provider: account?.kind ?? .github),
            hostName: capabilities?.hostName ?? "the web",
            pullRequestTerm: capabilities?.pullRequestTerm ?? "Pull request",
            remote: remote,
            lastSeenAt: baseline,
            whatsNew: detail == nil ? [] : WhatsNew.events(in: timeline, lastSeenAt: baseline, me: me),
            highlightedEventIDs: highlighted,
            me: me
        )
    }

    func actions(for item: WorkItem) -> DetailActions {
        DetailActions(
            open: { [weak self] url in self?.open(url, about: item) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            openTokenSetup: {
                if let url = URL(string: Links.tokenGuide) { NSWorkspace.shared.open(url) }
            },
            retry: { [weak self] in self?.reload() }
        )
    }

    /// Sample items are made up, so their links explain themselves instead of opening a page that does not exist.
    func open(_ url: URL, about item: WorkItem) {
        guard !environment.usesSampleContent else {
            environment.open(item)
            return
        }
        NSWorkspace.shared.open(url)
    }
}

extension AppEnvironment {
    /// The item with this id in the current snapshot.
    func item(id: String) -> WorkItem? {
        snapshot?.items.first { $0.id == id }
    }
}
