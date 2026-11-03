import GitwallCore
import SwiftUI

/// A titled block of the first screen.
struct DetailGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grey lines where a remote part will appear; the snapshot parts never wait for it.
struct DetailPlaceholder: View {
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<lines, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(height: 9)
                    .frame(maxWidth: index == lines - 1 ? 180 : .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel("Loading")
    }
}

/// Why one part cannot be shown, and what helps: the token setup for a refusal, trying again for anything else.
struct DetailSectionError: View {
    let error: DetailError
    /// "the checks", "the conversation".
    let what: String
    let actions: DetailActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch error {
            case .missingPermission:
                Label("GitHub did not let this token read \(what). The rest of Detail works.", systemImage: "lock")
                    .fixedSize(horizontal: false, vertical: true)
                // Try Again after the token's permissions were changed on GitHub; the token itself stays the same.
                HStack(spacing: 12) {
                    Button("Token setup…", action: actions.openTokenSetup).buttonStyle(.link)
                    Button("Try Again", action: actions.retry).buttonStyle(.link)
                }
            case .failed(let message):
                Label("Could not load \(what): \(message)", systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: actions.retry).buttonStyle(.link)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct DetailHeader: View {
    let content: DetailContent

    var body: some View {
        let item = content.item
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: ItemPresentation.kindSymbol(for: item.kind)).foregroundStyle(.secondary)
                Text(verbatim: "\(item.repoFullName)#\(item.number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let priority = ItemPresentation.priorityBadge(for: item) {
                    Capsule().fill(priority.tone.color.opacity(0.15))
                        .overlay(Text(priority.text).font(.caption.weight(.semibold)).foregroundStyle(priority.tone.color))
                        .frame(width: 30, height: 18)
                        .help(priority.help)
                }
                if item.isDraft {
                    Text("Draft").font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(item.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Group {
                    if let avatar = content.authorAvatar {
                        avatar.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                Text(item.author.login).fontWeight(.medium)
                Text("· opened \(DetailPresentation.ago(item.createdAt, now: content.now)) · updated \(DetailPresentation.ago(item.updatedAt, now: content.now))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.callout)
        }
    }
}

/// "mara · approved · 2h" and a link to the comment or review itself.
struct DetailAuthorLine: View {
    let login: String
    let verdict: ReviewVerdict?
    let date: Date
    let now: Date
    let url: URL?
    let actions: DetailActions

    var body: some View {
        HStack(spacing: 6) {
            Text(login).fontWeight(.semibold)
            if let verdict, let text = Self.text(for: verdict) {
                Text(text.0).font(.caption.weight(.medium)).foregroundStyle(text.1)
            }
            Spacer(minLength: 4)
            Text(ItemPresentation.compactAge(since: date, now: now)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let url {
                Button {
                    actions.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Open on the web")
            }
        }
        .font(.callout)
    }

    static func text(for verdict: ReviewVerdict) -> (String, Color)? {
        switch verdict {
        case .approved: ("approved", .green)
        case .changesRequested: ("requested changes", .red)
        case .commented: ("reviewed", .secondary)
        case .dismissed: ("dismissed", .secondary)
        case .pending: nil
        }
    }
}

struct DetailEventRow: View {
    let event: TimelineEvent
    let isHighlighted: Bool
    let now: Date
    let actions: DetailActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: DetailPresentation.symbol(for: event))
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(DetailPresentation.describe(event))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(ItemPresentation.compactAge(since: event.createdAt, now: now))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { if let url = event.url { actions.open(url) } }
        .help(event.url == nil ? "" : "Open on the web")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

/// Reviewers, checks, merge state, size and branch of a pull request.
struct DetailPullRequestStatus: View {
    let content: DetailContent
    let actions: DetailActions
    @State private var showsPassed = false

    private var item: WorkItem { content.item }

    var body: some View {
        DetailGroup("\(content.pullRequestTerm) status") {
            reviewers
            checks
            merge
            size
            branch
        }
    }

    @ViewBuilder
    private var reviewers: some View {
        let reviews = (try? content.detail?.reviews.get()) ?? nil
        let reviewers = DetailPresentation.reviewers(for: item, reviews: content.detail == nil ? nil : reviews ?? [])
        if reviewers.isEmpty {
            Label("No reviewers", systemImage: "person.2").foregroundStyle(.secondary)
        } else {
            ForEach(reviewers) { reviewer in
                let (symbol, text, color) = Self.describe(reviewer.state)
                Label {
                    Text(reviewer.login).fontWeight(.medium) + Text(" \(text)").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
            }
        }
    }

    static func describe(_ state: DetailPresentation.Reviewer.State) -> (String, String, Color) {
        switch state {
        case .approved: ("checkmark.circle.fill", "approved", .green)
        case .changesRequested: ("xmark.circle.fill", "requested changes", .red)
        case .commented: ("bubble.left", "commented", .secondary)
        case .dismissed: ("minus.circle", "review dismissed", .secondary)
        case .reviewed: ("eye", "reviewed", .secondary)
        case .requested: ("clock", "review requested", .orange)
        }
    }

    @ViewBuilder
    private var checks: some View {
        switch content.detail?.checks {
        case .success(let checks)?:
            if checks.isEmpty {
                Label("No checks", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                checkList(DetailPresentation.CheckSummary(checks))
            }
        case .failure(let error)?:
            DetailSectionError(error: error, what: "the checks", actions: actions)
        case nil:
            HStack(spacing: 6) {
                snapshotChecks
                if content.isLoading { ProgressView().controlSize(.mini) }
            }
        }
    }

    /// What the last sync knows before the checks load, or for a provider without Detail.
    @ViewBuilder
    private var snapshotChecks: some View {
        switch item.ciState ?? .none {
        case .success: Label("Checks passed", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failure: Label("Checks failing", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .running: Label("Checks running", systemImage: "circle.dotted").foregroundStyle(.orange)
        case .none: Label("No checks", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func checkList(_ summary: DetailPresentation.CheckSummary) -> some View {
        ForEach(summary.failed) { check in
            checkRow(check, symbol: "xmark.circle.fill", color: .red)
        }
        ForEach(summary.running) { check in
            checkRow(check, symbol: "circle.dotted", color: .orange)
        }
        if !summary.passed.isEmpty {
            DisclosureGroup(isExpanded: $showsPassed) {
                ForEach(summary.passed) { check in
                    checkRow(check, symbol: "checkmark.circle", color: .green)
                }
            } label: {
                Label(summary.passedLabel, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        if !summary.skipped.isEmpty {
            Label("\(summary.skipped.count) skipped", systemImage: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func checkRow(_ check: DetailCheck, symbol: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(check.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let url = check.url {
                Button("Log") { actions.open(url) }.buttonStyle(.link).help(url.absoluteString)
            }
        }
    }

    @ViewBuilder
    private var merge: some View {
        switch item.mergeState ?? .unknown {
        case .clean: Label("No conflicts", systemImage: "arrow.triangle.merge").foregroundStyle(.secondary)
        case .conflict: Label("Merge conflict", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .unknown: Label("Mergeability not known yet", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var size: some View {
        if let additions = item.additions, let deletions = item.deletions {
            HStack(spacing: 6) {
                Image(systemName: "plusminus").foregroundStyle(.secondary).frame(width: 16)
                Text("+\(additions)").foregroundStyle(.green).monospacedDigit()
                Text("−\(deletions)").foregroundStyle(.red).monospacedDigit()
                if let files = try? content.detail?.files.get() {
                    Text("· \(files.totalCount) file\(files.totalCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var branch: some View {
        if let branches = (try? content.detail?.branches.get()) ?? nil {
            HStack(spacing: 6) {
                Image(systemName: "arrow.branch").foregroundStyle(.secondary).frame(width: 16)
                Text(branches.head).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("→ \(branches.base)").font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    actions.copy(branches.head)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy Branch Name (⌥⌘C)")
            }
        }
    }
}

/// Comments and reviews with a text, oldest first, as on the provider.
/// A review without a summary: what it was instead of an empty text.
struct DetailSilentReview: View {
    let verdict: ReviewVerdict
    let inlineCommentCount: Int

    var body: some View {
        Text(DetailPresentation.silentReview(verdict, inlineCommentCount: inlineCommentCount))
            .font(.callout.italic())
            .foregroundStyle(.secondary)
    }
}

struct DetailConversation: View {
    let content: DetailContent
    let actions: DetailActions

    private struct Entry: Identifiable {
        let id: String
        let author: String
        let verdict: ReviewVerdict?
        let body: String
        var inlineCommentCount = 0
        let date: Date
        let url: URL?
    }

    var body: some View {
        if content.isLoading {
            DetailPlaceholder(lines: 3)
        } else if let detail = content.detail {
            if case .failure(let error) = detail.comments {
                DetailSectionError(error: error, what: "the conversation", actions: actions)
            } else {
                entries(detail)
            }
        } else {
            Text("Open it on \(content.hostName) to see the conversation.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func entries(_ detail: ItemDetail) -> some View {
        let comments = ((try? detail.comments.get()) ?? []).map {
            Entry(id: $0.id, author: $0.author.login, verdict: nil, body: $0.body, date: $0.createdAt, url: $0.url)
        }
        let reviews = ((try? detail.reviews.get()) ?? []).filter { $0.verdict != .pending }.map {
            Entry(id: $0.id, author: $0.author.login, verdict: $0.verdict, body: $0.body, inlineCommentCount: $0.inlineCommentCount,
                  date: $0.submittedAt, url: $0.url)
        }
        let all = (comments + reviews).sorted { $0.date < $1.date }
        VStack(alignment: .leading, spacing: 14) {
            if all.isEmpty {
                Text("No comments yet.").foregroundStyle(.secondary)
            }
            if content.item.commentCount > comments.count {
                Button("Earlier comments on \(content.hostName)…") { actions.open(content.item.url) }.buttonStyle(.link)
            }
            ForEach(all) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    DetailAuthorLine(login: entry.author, verdict: entry.verdict, date: entry.date, now: content.now, url: entry.url,
                                     actions: actions)
                    if let verdict = entry.verdict, entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSilentReview(verdict: verdict, inlineCommentCount: entry.inlineCommentCount)
                    } else {
                        MarkdownView(entry.body).font(.callout)
                    }
                }
            }
        }
    }
}

struct DetailFiles: View {
    let files: ChangedFiles
    let item: WorkItem
    let hostName: String
    let actions: DetailActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files.files) { file in
                HStack(spacing: 6) {
                    Text(file.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.head).help(file.path)
                    Spacer(minLength: 4)
                    Text("+\(file.additions)").font(.caption).foregroundStyle(.green).monospacedDigit()
                    Text("−\(file.deletions)").font(.caption).foregroundStyle(.red).monospacedDigit()
                }
            }
            if files.totalCount > files.files.count {
                Button("\(files.totalCount - files.files.count) more on \(hostName)…") {
                    actions.open(item.url.appendingPathComponent("files"))
                }
                .buttonStyle(.link)
            }
            if files.files.isEmpty { Text("No files changed.").foregroundStyle(.secondary) }
        }
    }
}

struct DetailLinked: View {
    let items: [LinkedItem]
    let actions: DetailActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty { Text("Nothing linked.").foregroundStyle(.secondary) }
            ForEach(items) { linked in
                Button {
                    actions.open(linked.url)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: ItemPresentation.kindSymbol(for: linked.kind))
                            .foregroundStyle(linked.state == .open ? .green : linked.state == .merged ? .purple : .secondary)
                        Text(verbatim: "\(linked.repoFullName)#\(linked.number)").foregroundStyle(.secondary).monospacedDigit()
                        Text(linked.title).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(linked.url.absoluteString)
            }
        }
        .font(.callout)
    }
}

struct DetailMetadata: View {
    let item: WorkItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.labels.isEmpty {
                Text("No labels").foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(item.labels, id: \.name) { label in
                        Text(label.name)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((Color(hex: label.colorHex) ?? .secondary).opacity(0.2), in: Capsule())
                    }
                }
            }
            Label(item.assignees.isEmpty ? "No assignees" : item.assignees.map(\.login).joined(separator: ", "),
                  systemImage: "person.crop.circle")
            Label(item.milestone ?? "No milestone", systemImage: "flag")
        }
        .font(.callout)
        .foregroundStyle(.primary)
    }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
