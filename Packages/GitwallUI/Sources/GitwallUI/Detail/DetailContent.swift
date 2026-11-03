import GitwallCore
import SwiftUI

/// Everything ``DetailView`` shows for one item. The snapshot parts are there at once; `remote` is nil while the
/// provider is asked.
public struct DetailContent {
    public var item: WorkItem
    public var authorAvatar: Image?
    /// The preset the item was opened from, for "Why it's here".
    public var presetName: String?
    public var reasons: [MatchReason]
    public var nextStep: NextStep
    /// "GitHub" or "GitLab".
    public var hostName: String
    /// "Pull request" or "Merge request".
    public var pullRequestTerm: String
    public var remote: DetailLoad?
    /// When the item was opened in Detail before this time; nil the first time.
    public var lastSeenAt: Date?
    public var whatsNew: [TimelineEvent]
    /// Events that arrived while the item was on screen.
    public var highlightedEventIDs: Set<String>
    public var me: UserRef?
    public var now: Date

    public init(
        item: WorkItem,
        authorAvatar: Image? = nil,
        presetName: String?,
        reasons: [MatchReason],
        nextStep: NextStep,
        hostName: String,
        pullRequestTerm: String,
        remote: DetailLoad?,
        lastSeenAt: Date?,
        whatsNew: [TimelineEvent],
        highlightedEventIDs: Set<String> = [],
        me: UserRef?,
        now: Date = Date()
    ) {
        self.item = item
        self.authorAvatar = authorAvatar
        self.presetName = presetName
        self.reasons = reasons
        self.nextStep = nextStep
        self.hostName = hostName
        self.pullRequestTerm = pullRequestTerm
        self.remote = remote
        self.lastSeenAt = lastSeenAt
        self.whatsNew = whatsNew
        self.highlightedEventIDs = highlightedEventIDs
        self.me = me
        self.now = now
    }

    var detail: ItemDetail? {
        if case .loaded(let detail)? = remote { return detail }
        return nil
    }

    var isLoading: Bool { remote == nil }
}

/// What ``DetailView`` can ask its owner to do. Gitwall is read-only, so every action opens, copies or reloads.
public struct DetailActions {
    public var open: (URL) -> Void
    public var copy: (String) -> Void
    /// The token guide, for a part the token may not read.
    public var openTokenSetup: () -> Void
    public var retry: () -> Void

    public init(open: @escaping (URL) -> Void, copy: @escaping (String) -> Void, openTokenSetup: @escaping () -> Void,
                retry: @escaping () -> Void) {
        self.open = open
        self.copy = copy
        self.openTokenSetup = openTokenSetup
        self.retry = retry
    }
}

/// The collapsed sections below the first screen.
public enum DetailFold: String, CaseIterable, Hashable, Sendable {
    case description, conversation, files, linked, metadata
}
