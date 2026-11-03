import Foundation

/// Why one part of ``ItemDetail`` could not be read. Each part fails on its own, so a token that may not read the
/// checks still shows the conversation. See `docs/adr/0015-detail-is-read-only-and-fetched-on-demand.md`.
public enum DetailError: Error, Hashable, Sendable {
    /// The credential may not read this part; Detail points to the token setup.
    case missingPermission
    /// Anything else, such as the network or the rate limit.
    case failed(String)
}

/// One part of ``ItemDetail``: its value, or why it could not be read.
public typealias DetailSection<Value> = Result<Value, DetailError>

/// What Detail shows beyond the snapshot, fetched on demand for one item and never stored in the App Group.
/// Issues have no reviews, checks, files or branches; theirs are empty.
public struct ItemDetail: Hashable, Sendable {
    /// ``WorkItem/id`` of the item this belongs to.
    public var itemID: String
    /// ``WorkItem/updatedAt`` the item had when this was fetched; a newer one makes it stale.
    public var itemUpdatedAt: Date
    public var fetchedAt: Date
    /// Markdown, as written on the provider.
    public var body: DetailSection<String>
    /// Head and base branch of a pull request; nil for an issue.
    public var branches: DetailSection<Branches?>
    /// The most recent comments, oldest first.
    public var comments: DetailSection<[DetailComment]>
    /// The most recent reviews, oldest first.
    public var reviews: DetailSection<[DetailReview]>
    /// The most recent events, oldest first.
    public var timeline: DetailSection<[TimelineEvent]>
    /// Issues a pull request closes, or pull requests that close an issue.
    public var linkedItems: DetailSection<[LinkedItem]>
    /// Checks and statuses of the pull request's last commit.
    public var checks: DetailSection<[DetailCheck]>
    public var files: DetailSection<ChangedFiles>

    public init(
        itemID: String,
        itemUpdatedAt: Date,
        fetchedAt: Date,
        body: DetailSection<String> = .success(""),
        branches: DetailSection<Branches?> = .success(nil),
        comments: DetailSection<[DetailComment]> = .success([]),
        reviews: DetailSection<[DetailReview]> = .success([]),
        timeline: DetailSection<[TimelineEvent]> = .success([]),
        linkedItems: DetailSection<[LinkedItem]> = .success([]),
        checks: DetailSection<[DetailCheck]> = .success([]),
        files: DetailSection<ChangedFiles> = .success(ChangedFiles(files: [], totalCount: 0))
    ) {
        self.itemID = itemID
        self.itemUpdatedAt = itemUpdatedAt
        self.fetchedAt = fetchedAt
        self.body = body
        self.branches = branches
        self.comments = comments
        self.reviews = reviews
        self.timeline = timeline
        self.linkedItems = linkedItems
        self.checks = checks
        self.files = files
    }

    /// Every part's failure, to tell a passing hiccup (worth fetching again) from a missing permission (not).
    public var failures: [DetailError] {
        func failure<Value>(_ section: DetailSection<Value>) -> DetailError? {
            if case .failure(let error) = section { return error }
            return nil
        }
        return [
            failure(body), failure(branches), failure(comments), failure(reviews), failure(timeline),
            failure(linkedItems), failure(checks), failure(files),
        ].compactMap { $0 }
    }
}

public struct Branches: Hashable, Sendable {
    public var head: String
    public var base: String

    public init(head: String, base: String) {
        self.head = head
        self.base = base
    }
}

public struct DetailComment: Hashable, Sendable, Identifiable {
    public var id: String
    public var author: UserRef
    public var body: String
    public var createdAt: Date
    public var url: URL?

    public init(id: String, author: UserRef, body: String, createdAt: Date, url: URL?) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

/// What a single review said; ``ReviewState`` is the pull request's overall state.
public enum ReviewVerdict: String, Hashable, Sendable {
    case approved
    case changesRequested
    case commented
    case dismissed
    /// Started but not submitted; only its author sees it.
    case pending
}

public struct DetailReview: Hashable, Sendable, Identifiable {
    public var id: String
    public var author: UserRef
    public var verdict: ReviewVerdict
    public var body: String
    public var submittedAt: Date
    public var url: URL?

    public init(id: String, author: UserRef, verdict: ReviewVerdict, body: String, submittedAt: Date, url: URL?) {
        self.id = id
        self.author = author
        self.verdict = verdict
        self.body = body
        self.submittedAt = submittedAt
        self.url = url
    }
}

public enum CheckState: String, Hashable, Sendable {
    case passed
    case failed
    case running
    /// Skipped, neutral or stale: neither passed nor failed.
    case skipped
}

/// A check run or a commit status, by name.
public struct DetailCheck: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var state: CheckState
    /// Its log or details page, when the provider gives one.
    public var url: URL?

    public init(name: String, state: CheckState, url: URL?) {
        self.name = name
        self.state = state
        self.url = url
    }
}

public struct ChangedFile: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var additions: Int
    public var deletions: Int

    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }
}

/// The first files of a pull request; `totalCount` says how many it changes in all.
public struct ChangedFiles: Hashable, Sendable {
    public var files: [ChangedFile]
    public var totalCount: Int

    public init(files: [ChangedFile], totalCount: Int) {
        self.files = files
        self.totalCount = totalCount
    }
}

public struct LinkedItem: Hashable, Sendable, Identifiable {
    public enum State: String, Hashable, Sendable {
        case open, closed, merged
    }

    public var id: String { "\(repoFullName)#\(number)" }
    public var kind: ItemKind
    public var repoFullName: String
    public var number: Int
    public var title: String
    public var url: URL
    public var state: State

    public init(kind: ItemKind, repoFullName: String, number: Int, title: String, url: URL, state: State) {
        self.kind = kind
        self.repoFullName = repoFullName
        self.number = number
        self.title = title
        self.url = url
        self.state = state
    }
}

/// Something that happened on an item: the source of "What's new".
public struct TimelineEvent: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case commented
        case reviewed(ReviewVerdict)
        /// A commit pushed to the pull request; `sha` is abbreviated.
        case committed(sha: String, message: String)
        case labeled(String)
        case unlabeled(String)
        case readyForReview
        /// A review requested from a person or a team.
        case reviewRequested(String)
        case assigned(String)
        case forcePushed(sha: String?)
    }

    public var id: String
    public var kind: Kind
    /// Who did it; nil when the provider does not say (a commit by someone without an account).
    public var actor: UserRef?
    public var createdAt: Date
    /// Where it can be seen, when it has its own place (a comment, a review, a commit).
    public var url: URL?

    public init(id: String, kind: Kind, actor: UserRef?, createdAt: Date, url: URL? = nil) {
        self.id = id
        self.kind = kind
        self.actor = actor
        self.createdAt = createdAt
        self.url = url
    }
}
