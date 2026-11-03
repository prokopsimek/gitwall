import AppKit
import GitwallCore
import GitwallUI
import Observation
import OSLog
import SwiftUI

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "detail")

/// Detail in one window: which item is selected, whether the panel shows, and what has been fetched for it. Any
/// window attaches it with ``SwiftUI/View/itemDetailInspector(_:environment:preset:)`` and, for the Item menu,
/// ``ItemWindowController``. Arrowing through a list asks the provider only once the selection rests for
/// ``debounce``; an item already fetched in its current state shows at once. An item counts as seen once its detail
/// has loaded while it is still on screen (see ``markSeen(_:after:)``).
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
    /// How long an item without a fetch (sample data, a provider without Detail, no credential) must stay on screen
    /// before it counts as seen.
    @ObservationIgnored let seenDelay: Duration
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var openedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        environment: AppEnvironment,
        seenDelay: Duration = .seconds(1),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.environment = environment
        self.seenDelay = seenDelay
        self.openURL = openURL
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

    /// Another preset is on screen: a selection that is not in its list goes, so Detail never explains an item by a
    /// preset it is not in. A sync that drops the item keeps it; ``content(for:preset:)`` then leaves the preset out.
    func presetDidChange(visibleItemIDs ids: [String]) {
        visibleItemIDs = ids
        if let selectedItemID, !ids.contains(selectedItemID) { select(nil) }
    }

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
        openedAt = Date()
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
        await markSeen(item, after: load)
    }

    /// Seen means its state was in front of me: a fetched detail whose timeline loaded counts from the moment it was
    /// fetched. Without a fetch, the item has to stay on screen for ``seenDelay``. Either way it must still be the one
    /// shown; a detail whose timeline failed is not seen, so What's new keeps its events.
    private func markSeen(_ item: WorkItem, after load: DetailLoad) async {
        let date: Date
        switch load {
        case .loaded(let detail) where !environment.usesSampleContent:
            guard case .success = detail.timeline else { return }
            date = detail.fetchedAt
        case .loaded, .unsupported, .noCredential:
            try? await Task.sleep(for: seenDelay)
            date = Date()
        }
        guard !Task.isCancelled, isPresented, selectedItemID == item.id else { return }
        service.markSeen(item, at: date, liveItemIDs: Set(environment.snapshot?.items.map(\.id) ?? []),
                         persist: !environment.usesSampleContent)
    }

    // MARK: Content

    /// What ``DetailView`` shows for `item`, opened from `preset`. The preset explains the item only while the item is
    /// in the list on screen.
    func content(for item: WorkItem, preset: Preset?) -> DetailContent {
        let preset = visibleItemIDs.contains(item.id) ? preset : nil
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

    /// Links come from other people's text, so only web pages open (``DetailPresentation/isOpenable(_:)``). Sample
    /// items are made up, so their links explain themselves instead of opening a page that does not exist.
    func open(_ url: URL, about item: WorkItem) {
        guard DetailPresentation.isOpenable(url) else {
            log.notice("Ignored a link that is not a web page (\(url.scheme ?? "no scheme", privacy: .public)) in \(DetailPresentation.reference(of: item), privacy: .private)")
            return
        }
        guard !environment.usesSampleContent else {
            environment.open(item)
            return
        }
        openURL(url)
    }
}

extension AppEnvironment {
    /// The item with this id in the current snapshot.
    func item(id: String) -> WorkItem? {
        snapshot?.items.first { $0.id == id }
    }
}
