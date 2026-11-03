import GitwallCore
import SwiftUI

/// Detail of one item, for an inspector next to a list. The first screen holds what a decision needs: why the item
/// is here, the next step, the latest word, the pull request's status and what is new. The rest is folded below.
/// Read-only: every link opens the provider through ``DetailActions``.
public struct DetailView: View {
    let content: DetailContent
    let actions: DetailActions
    @State private var expanded: Set<DetailFold>
    @State private var showsWholeLatestWord = false
    private let scrollsToExpanded: Bool

    /// `initiallyExpanded` opens folds from the start; `scrollsToExpanded` scrolls to the first of them, so a
    /// screenshot can show one without scrolling by hand.
    public init(content: DetailContent, actions: DetailActions, initiallyExpanded: Set<DetailFold> = [], scrollsToExpanded: Bool = false) {
        self.content = content
        self.actions = actions
        self.scrollsToExpanded = scrollsToExpanded
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var item: WorkItem { content.item }
    private var isPullRequest: Bool { item.kind == .pullRequest }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DetailHeader(content: content).id("top")
                    whyItsHere
                    nextStep
                    remoteNotice
                    latestWord
                    if isPullRequest { DetailPullRequestStatus(content: content, actions: actions) }
                    whatsNew
                    Divider()
                    folds
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: item.id) {
                showsWholeLatestWord = false
                proxy.scrollTo("top", anchor: .top)
            }
            .task(id: item.id) {
                guard scrollsToExpanded, let first = DetailFold.allCases.first(where: expanded.contains) else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo(first, anchor: .top)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            actions.open(url)
            return .handled
        })
    }

    // MARK: First screen

    @ViewBuilder
    private var whyItsHere: some View {
        let why = DetailPresentation.WhyItsHere(content.reasons, presetName: content.presetName)
        let facts = why.facts
        if !why.isEmpty {
            DetailGroup("Why it's here") {
                if let presetName = why.presetName, why.presetLine != nil {
                    Label {
                        Text("Matches ") + Text(why.terms.joined(separator: " ")).font(.callout.monospaced())
                            + Text(" in “\(presetName)”")
                    } icon: {
                        Image(systemName: DetailPresentation.symbol(for: .queryTerm("")))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(why.presetLine ?? "")
                }
                ForEach(facts, id: \.self) { fact in
                    Label(DetailPresentation.describe(fact, pullRequestTerm: content.pullRequestTerm),
                          systemImage: DetailPresentation.symbol(for: fact))
                        .foregroundStyle(tone(of: fact))
                }
            }
        }
    }

    private func tone(of reason: MatchReason) -> Color {
        switch reason {
        case .failingChecks, .mergeConflict, .changesRequestedOnMyPullRequest: .red
        case .reviewRequestedFromMe, .assignedToMe: .primary
        case .queryTerm: .secondary
        }
    }

    private var nextStep: some View {
        let step = content.nextStep
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                actions.open(step.url)
            } label: {
                Label(DetailPresentation.title(of: step.action, hostName: content.hostName), systemImage: symbol(for: step.action))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(step.url.absoluteString)
            .accessibilityIdentifier("detail-next-step")
            if step.action == .readyToMerge {
                Text("Approved, checks passed, no conflict. Merge on \(content.hostName).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(for action: NextStep.Action) -> String {
        switch action {
        case .reviewChanges: "doc.text.magnifyingglass"
        case .reply: "arrowshape.turn.up.left"
        case .openFailingCheck: "exclamationmark.triangle"
        case .readyToMerge: "arrow.triangle.merge"
        case .open: "arrow.up.forward.app"
        }
    }

    /// Why only the snapshot shows: a provider without Detail, or no token.
    @ViewBuilder
    private var remoteNotice: some View {
        switch content.remote {
        case .unsupported?:
            Label("Comments, checks and files are fetched from GitHub only for now. Everything else here is from the last sync.",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .noCredential?:
            HStack(alignment: .firstTextBaseline) {
                Label("No token is stored for this account, so only the last sync shows here.", systemImage: "key")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Token setup…", action: actions.openTokenSetup).buttonStyle(.link)
            }
            .font(.callout).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var latestWord: some View {
        if content.isLoading {
            DetailGroup("Latest word") { DetailPlaceholder(lines: 3) }
        } else if let detail = content.detail {
            DetailGroup("Latest word") {
                if case .failure(let error) = detail.comments {
                    DetailSectionError(error: error, what: "the conversation", actions: actions)
                } else {
                    latestWordBody(LatestWord.find(in: detail, me: content.me))
                }
            }
        }
    }

    @ViewBuilder
    private func latestWordBody(_ word: LatestWord) -> some View {
        switch word {
        case .none:
            Text(DetailPresentation.quietConversation((try? content.detail?.comments.get()) ?? [])).foregroundStyle(.secondary)
        case .youRepliedLast(let date):
            Label("You replied last · \(DetailPresentation.ago(date, now: content.now))",
                  systemImage: "arrowshape.turn.up.left")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("detail-you-replied-last")
        case .fromOther(let utterance):
            let blocks = MarkdownBlock.parse(utterance.body)
            let shortened = !showsWholeLatestWord && blocks.count > 4
            VStack(alignment: .leading, spacing: 8) {
                DetailAuthorLine(login: utterance.author.login, verdict: utterance.verdict, date: utterance.date, now: content.now,
                                 url: utterance.url, actions: actions)
                if let verdict = utterance.verdict, blocks.isEmpty {
                    DetailSilentReview(verdict: verdict, inlineCommentCount: utterance.inlineCommentCount)
                }
                MarkdownView(blocks: shortened ? Array(blocks.prefix(4)) : blocks)
                    .font(.callout)
                if shortened {
                    Button("Show all") { showsWholeLatestWord = true }.buttonStyle(.link).font(.callout)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var whatsNew: some View {
        let title = content.lastSeenAt.map { "What's new since \(DetailPresentation.ago($0, now: content.now))" }
            ?? "Recent activity"
        switch content.remote {
        case nil:
            DetailGroup(title) { DetailPlaceholder(lines: 2) }
        case .loaded(let detail)?:
            DetailGroup(title) {
                if case .failure(let error) = detail.timeline {
                    DetailSectionError(error: error, what: "the timeline", actions: actions)
                } else if content.whatsNew.isEmpty {
                    Text("Nothing new since you last opened it.").foregroundStyle(.secondary)
                } else {
                    ForEach(content.whatsNew.reversed()) { event in
                        DetailEventRow(event: event, isHighlighted: content.highlightedEventIDs.contains(event.id), now: content.now,
                                       actions: actions)
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Folded

    private func binding(_ fold: DetailFold) -> Binding<Bool> {
        Binding(get: { expanded.contains(fold) }, set: { if $0 { expanded.insert(fold) } else { expanded.remove(fold) } })
    }

    private var folds: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: binding(.description)) {
                remotePart(content.detail?.body, what: "the description") { body in
                    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description.").foregroundStyle(.secondary)
                    } else {
                        MarkdownView(body).font(.callout)
                    }
                }
                .padding(.top, 6)
            } label: {
                foldLabel("Description")
            }
            .id(DetailFold.description)
            DisclosureGroup(isExpanded: binding(.conversation)) {
                DetailConversation(content: content, actions: actions).padding(.top, 6)
            } label: {
                foldLabel("Conversation", count: item.commentCount)
            }
            .id(DetailFold.conversation)
            if isPullRequest {
                DisclosureGroup(isExpanded: binding(.files)) {
                    remotePart(content.detail?.files, what: "the files") { files in
                        DetailFiles(files: files, item: item, hostName: content.hostName, actions: actions)
                    }
                    .padding(.top, 6)
                } label: {
                    foldLabel("Files", count: (try? content.detail?.files.get())?.totalCount)
                }
                .id(DetailFold.files)
            }
            DisclosureGroup(isExpanded: binding(.linked)) {
                remotePart(content.detail?.linkedItems, what: "the linked items") { linked in
                    DetailLinked(items: linked, actions: actions)
                }
                .padding(.top, 6)
            } label: {
                foldLabel("Linked", count: (try? content.detail?.linkedItems.get())?.count)
            }
            .id(DetailFold.linked)
            DisclosureGroup(isExpanded: binding(.metadata)) {
                DetailMetadata(item: item).padding(.top, 6)
            } label: {
                foldLabel("Labels, assignees, milestone")
            }
            .id(DetailFold.metadata)
        }
    }

    private func foldLabel(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.medium)
            if let count { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    /// A part of the remote detail: a placeholder while it loads, the reason when it cannot be read, nothing for a
    /// provider without Detail.
    @ViewBuilder
    private func remotePart<Value, Body: View>(
        _ section: DetailSection<Value>?,
        what: String,
        @ViewBuilder _ body: @escaping (Value) -> Body
    ) -> some View {
        switch (content.remote, section) {
        case (nil, _):
            DetailPlaceholder(lines: 2)
        case (_, .success(let value)?):
            body(value)
        case (_, .failure(let error)?):
            DetailSectionError(error: error, what: what, actions: actions)
        default:
            Text("Open it on \(content.hostName) to see this.").foregroundStyle(.secondary)
        }
    }
}
