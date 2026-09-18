import Foundation

/// Deterministic sample content: the user-facing sample data mode, widgets without an account, and the
/// `--debug-demo` launch mode (App Store screenshots, UI work). The app swaps its stores for this data, so nothing
/// here is read from or written to the App Group. Names are fictional; keep real customers and colleagues out.
public enum DemoData {
    public static let me = UserRef(login: "prokop", displayName: "Prokop Simek")

    public static let github = Account(
        id: fixedID(0x01), kind: .github, baseURL: URL(string: "https://github.com")!,
        displayName: "GitHub (prokop)", me: me,
        sources: [.organization(login: "northwind"), .repository(fullName: "prokop/dotfiles")]
    )

    public static let gitlab = Account(
        id: fixedID(0x02), kind: .gitlab, baseURL: URL(string: "https://git.northwind.dev")!,
        displayName: "git.northwind.dev (prokop)", me: me,
        sources: [.group(fullPath: "platform", includeSubgroups: true)]
    )

    public static let presets: [Preset] = [
        Preset(id: fixedID(0x10), name: "My pull requests", icon: "person.crop.circle",
               kinds: [.pullRequest], filter: ItemFilter(relations: [.authoredByMe])),
        Preset(id: fixedID(0x11), name: "Waiting for my review", icon: "eye",
               kinds: [.pullRequest], filter: ItemFilter(relations: [.reviewRequestedFromMe], includeDrafts: false),
               showCountInMenuBar: true),
        Preset(id: fixedID(0x12), name: "All open", icon: "tray.full", kinds: [.pullRequest, .issue]),
        Preset(id: fixedID(0x13), name: "Failing CI", icon: "flame",
               kinds: [.pullRequest], filter: ItemFilter(ciStates: [.failure])),
        Preset(id: fixedID(0x14), name: "Release 2.4", icon: "shippingbox",
               kinds: [.pullRequest, .issue], filter: ItemFilter(milestone: "2.4")),
        Preset(id: fixedID(0x15), name: "Open bugs", icon: "ladybug",
               kinds: [.issue], filter: ItemFilter(labelsAny: ["bug"])),
        // Deliberately busy: shows the filter editor with several options in use.
        Preset(id: fixedID(0x16), name: "Needs my attention", icon: "exclamationmark.triangle",
               scopes: [PresetScope(accountID: fixedID(0x01)), PresetScope(accountID: fixedID(0x02))],
               kinds: [.pullRequest],
               filter: ItemFilter(relations: [.reviewRequestedFromMe, .assignedToMe], includeDrafts: false,
                                  labelsNone: ["dependencies"], ciStates: [.failure, .running], updatedWithinDays: 7)),
    ]

    public static let config = AppConfig(accounts: [github, gitlab], presets: presets)

    /// How many review requests can arrive while someone presses Refresh in sample mode.
    public static var arrivalCount: Int { arrivals(now: Date()).count }

    /// A snapshot as if both accounts had just synced at `now`. `arrivals` adds that many new review requests on
    /// top, so pressing Refresh with sample data shows something arriving and can fire a notification.
    public static func snapshot(now: Date = Date(), arrivals count: Int = 0) -> Snapshot {
        Snapshot(
            fetchedAt: now,
            items: Array(arrivals(now: now).prefix(max(0, count)).reversed()) + items(now: now),
            accountStatus: [
                github.id: FetchStatus(state: .ok, lastSuccessAt: now),
                gitlab.id: FetchStatus(state: .ok, lastSuccessAt: now),
            ]
        )
    }

    /// What repository discovery lists for a sample account, so Settings › Repositories works without a token.
    public static func discovery(for accountID: UUID) -> (repositories: [RepoRef], containers: [ContainerRef]) {
        switch accountID {
        case github.id:
            return (
                [
                    RepoRef(fullName: "northwind/checkout-api", description: "Payments and order capture"),
                    RepoRef(fullName: "northwind/storefront", description: "Web shop front end"),
                    RepoRef(fullName: "northwind/design-system", description: "Shared UI components and tokens"),
                    RepoRef(fullName: "northwind/infra", description: "Clusters, DNS and alerting", isPrivate: true),
                    RepoRef(fullName: "prokop/dotfiles", description: "Shell and editor setup"),
                ],
                [ContainerRef(id: "northwind", name: "northwind", source: .organization(login: "northwind"))]
            )
        case gitlab.id:
            return (
                [
                    RepoRef(fullName: "platform/gateway", description: "API gateway", isPrivate: true),
                    RepoRef(fullName: "platform/auth-service", description: "Sign-in and sessions", isPrivate: true),
                    RepoRef(fullName: "platform/terraform", description: "Infrastructure as code", isPrivate: true),
                ],
                [ContainerRef(id: "platform", name: "platform", source: .group(fullPath: "platform", includeSubgroups: true))]
            )
        default:
            return ([], [])
        }
    }

    /// Presets a widget offers and shows. Without an account a widget shows sample data, and Edit Widget offers
    /// the sample presets, so each widget can still be set to its own view before anything is connected.
    public static func widgetPresets(for config: AppConfig) -> [Preset] {
        config.accounts.isEmpty ? presets : config.presets
    }

    // MARK: - Content

    private static let mara = UserRef(login: "mara-k", displayName: "Mara Kovac")
    private static let tomas = UserRef(login: "tomasn", displayName: "Tomas Novak")
    private static let jana = UserRef(login: "jana.v", displayName: "Jana Vesela")
    private static let ondrej = UserRef(login: "ondrej", displayName: "Ondrej Hruby")
    private static let renovate = UserRef(login: "renovate[bot]", displayName: "Renovate")

    private static let bug = Label(name: "bug", colorHex: "D73A4A")
    private static let enhancement = Label(name: "enhancement", colorHex: "A2EEEF")
    private static let dependencies = Label(name: "dependencies", colorHex: "0366D6")
    private static let frontend = Label(name: "frontend", colorHex: "FBCA04")
    private static let backend = Label(name: "backend", colorHex: "0E8A16")
    private static let infra = Label(name: "infra", colorHex: "5319E7")
    private static let security = Label(name: "security", colorHex: "B60205")

    private static func items(now: Date) -> [WorkItem] {
        func pull(
            _ account: Account, _ repo: String, _ number: Int, _ title: String, by author: UserRef, hoursAgo: Double,
            review: ReviewState, ci: CIState, merge: MergeState = .clean, draft: Bool = false, labels: [Label] = [],
            reviewers: [UserRef] = [], requested: [UserRef] = [], assignees: [UserRef] = [], milestone: String? = nil,
            comments: Int = 0, add: Int = 0, del: Int = 0, ageDays: Double = 2
        ) -> WorkItem {
            let path = account.kind == .github ? "pull" : "-/merge_requests"
            return WorkItem(
                accountID: account.id, kind: .pullRequest, repoFullName: repo, number: number, title: title,
                url: account.baseURL.appendingPathComponent("\(repo)/\(path)/\(number)"), author: author,
                createdAt: now.addingTimeInterval(-hoursAgo * 3_600 - ageDays * 86_400),
                updatedAt: now.addingTimeInterval(-hoursAgo * 3_600),
                isDraft: draft, labels: labels, assignees: assignees, milestone: milestone, commentCount: comments,
                reviewState: review, ciState: ci, mergeState: merge, reviewers: reviewers, requestedReviewers: requested,
                additions: add, deletions: del
            )
        }
        func issue(
            _ account: Account, _ repo: String, _ number: Int, _ title: String, by author: UserRef, hoursAgo: Double,
            labels: [Label] = [], assignees: [UserRef] = [], milestone: String? = nil, comments: Int = 0, ageDays: Double = 6
        ) -> WorkItem {
            let path = account.kind == .github ? "issues" : "-/issues"
            return WorkItem(
                accountID: account.id, kind: .issue, repoFullName: repo, number: number, title: title,
                url: account.baseURL.appendingPathComponent("\(repo)/\(path)/\(number)"), author: author,
                createdAt: now.addingTimeInterval(-hoursAgo * 3_600 - ageDays * 86_400),
                updatedAt: now.addingTimeInterval(-hoursAgo * 3_600),
                labels: labels, assignees: assignees, milestone: milestone, commentCount: comments
            )
        }

        return [
            pull(github, "northwind/checkout-api", 482, "Retry payment capture with exponential backoff", by: mara, hoursAgo: 0.2,
                 review: .pending, ci: .running, labels: [backend], requested: [me], milestone: "2.4", comments: 2, add: 164, del: 21),
            pull(github, "northwind/storefront", 1290, "Cart: keep promo code after login", by: me, hoursAgo: 0.6,
                 review: .approved, ci: .success, labels: [frontend], reviewers: [tomas], milestone: "2.4", comments: 4, add: 88, del: 40),
            pull(gitlab, "platform/gateway", 214, "Rate limiting per API key", by: ondrej, hoursAgo: 1.1,
                 review: .changesRequested, ci: .success, labels: [backend, security], reviewers: [me], comments: 7, add: 312, del: 96),
            issue(github, "northwind/storefront", 1287, "Checkout button unresponsive on Safari 18 with VoiceOver", by: jana, hoursAgo: 1.8,
                  labels: [bug, frontend], assignees: [me], milestone: "2.4", comments: 5),
            pull(github, "northwind/design-system", 356, "Button: loading state and reduced-motion spinner", by: jana, hoursAgo: 2.5,
                 review: .pending, ci: .success, labels: [frontend], requested: [me], comments: 1, add: 57, del: 12),
            pull(github, "northwind/infra", 97, "Migrate staging cluster to ARM nodes", by: tomas, hoursAgo: 3.2,
                 review: .pending, ci: .failure, merge: .conflict, labels: [infra], requested: [me, ondrej], comments: 9, add: 240, del: 233),
            pull(github, "northwind/checkout-api", 479, "Draft: idempotency keys for refunds", by: me, hoursAgo: 4,
                 review: .none, ci: .running, draft: true, labels: [backend], add: 71, del: 8),
            pull(gitlab, "platform/auth-service", 88, "Rotate signing keys without downtime", by: me, hoursAgo: 5.5,
                 review: .pending, ci: .success, labels: [security], requested: [ondrej], milestone: "2.4", comments: 3, add: 130, del: 44),
            pull(github, "northwind/storefront", 1284, "chore(deps): update next to 15.5.2", by: renovate, hoursAgo: 7,
                 review: .pending, ci: .failure, labels: [dependencies], requested: [me], add: 6, del: 6),
            issue(gitlab, "platform/gateway", 203, "Timeouts spike after deploy when upstream is cold", by: tomas, hoursAgo: 9,
                  labels: [bug, backend], assignees: [ondrej], comments: 11),
            pull(gitlab, "platform/terraform", 41, "Add read replica for reporting", by: ondrej, hoursAgo: 12,
                 review: .approved, ci: .success, labels: [infra], reviewers: [me, tomas], milestone: "2.4", comments: 2, add: 94, del: 3),
            pull(github, "northwind/design-system", 351, "Tokens: dark theme for data tables", by: mara, hoursAgo: 15,
                 review: .changesRequested, ci: .success, labels: [frontend], reviewers: [me], comments: 6, add: 198, del: 27),
            issue(github, "northwind/checkout-api", 471, "Support Apple Pay merchant validation renewals", by: mara, hoursAgo: 19,
                  labels: [enhancement, backend], milestone: "2.5", comments: 3),
            pull(github, "prokop/dotfiles", 12, "zsh: lazy-load nvm", by: me, hoursAgo: 26,
                 review: .none, ci: .none, add: 14, del: 30),
            pull(github, "northwind/storefront", 1276, "Order history: infinite scroll", by: jana, hoursAgo: 31,
                 review: .approved, ci: .success, labels: [frontend], reviewers: [me], milestone: "2.5", comments: 8, add: 402, del: 118),
            pull(gitlab, "platform/gateway", 209, "chore(deps): bump go to 1.25", by: renovate, hoursAgo: 40,
                 review: .pending, ci: .success, labels: [dependencies], requested: [me], add: 3, del: 3),
            issue(gitlab, "platform/auth-service", 77, "Document the session cookie attributes", by: jana, hoursAgo: 52,
                  labels: [enhancement], assignees: [me], comments: 1),
            pull(github, "northwind/infra", 95, "Alerting: page on-call for 5xx above 1 %", by: tomas, hoursAgo: 60,
                 review: .pending, ci: .success, labels: [infra], reviewers: [ondrej], requested: [me], comments: 4, add: 61, del: 9),
            issue(github, "northwind/storefront", 1268, "Product images load twice on first paint", by: ondrej, hoursAgo: 75,
                  labels: [bug, frontend], comments: 2),
            pull(github, "northwind/checkout-api", 466, "Draft: split tax calculation into its own service", by: tomas, hoursAgo: 96,
                 review: .none, ci: .running, draft: true, labels: [backend], comments: 12, add: 1_240, del: 380),
            issue(github, "northwind/infra", 91, "Terraform drift on the DNS module every night", by: me, hoursAgo: 120,
                  labels: [bug, infra], assignees: [tomas], comments: 6),
            pull(gitlab, "platform/terraform", 38, "S3 lifecycle rules for audit logs", by: mara, hoursAgo: 150,
                 review: .pending, ci: .failure, labels: [infra], requested: [me], comments: 1, add: 45, del: 2),
            issue(github, "northwind/design-system", 340, "Focus ring invisible on teal buttons", by: jana, hoursAgo: 190,
                  labels: [bug, frontend], milestone: "2.4", comments: 4),
        ]
    }

    /// New review requests, newest last in the order they arrive.
    private static func arrivals(now: Date) -> [WorkItem] {
        func request(_ account: Account, _ repo: String, _ number: Int, _ title: String, by author: UserRef, labels: [Label], add: Int, del: Int) -> WorkItem {
            let path = account.kind == .github ? "pull" : "-/merge_requests"
            return WorkItem(
                accountID: account.id, kind: .pullRequest, repoFullName: repo, number: number, title: title,
                url: account.baseURL.appendingPathComponent("\(repo)/\(path)/\(number)"), author: author,
                createdAt: now.addingTimeInterval(-120), updatedAt: now.addingTimeInterval(-60),
                labels: labels, reviewState: .pending, ciState: .running, mergeState: .clean,
                requestedReviewers: [me], additions: add, deletions: del
            )
        }
        return [
            request(github, "northwind/storefront", 1293, "Search: highlight matched terms in results", by: tomas, labels: [frontend], add: 76, del: 18),
            request(gitlab, "platform/gateway", 217, "Health check for the rate limiter store", by: mara, labels: [backend], add: 42, del: 5),
            request(github, "northwind/checkout-api", 486, "Log capture latency per payment provider", by: ondrej, labels: [backend], add: 58, del: 11),
            request(github, "northwind/design-system", 359, "Date picker: keyboard navigation", by: jana, labels: [frontend], add: 133, del: 29),
            request(gitlab, "platform/auth-service", 92, "Shorter session lifetime for admin roles", by: tomas, labels: [security], add: 24, del: 9),
        ]
    }

    private static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuidString: String(format: "6B1D0A2E-%02X00-4C61-9F4B-1D2A3B4C5D%02X", n, n))!
    }
}
