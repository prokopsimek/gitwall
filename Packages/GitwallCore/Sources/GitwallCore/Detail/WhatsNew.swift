import Foundation

/// What happened on an item since the signed-in account last opened it in Detail. Gitwall keeps that moment itself
/// (``SeenStore``); GitHub's notifications would need the `notifications` scope. See `docs/adr/0015`.
public enum WhatsNew {
    /// How many events the very first open shows, when there is no last open to compare with.
    public static let firstOpenCount = 3

    /// Events by other people after `lastSeenAt`, oldest first. Without a last open, the last
    /// ``firstOpenCount`` events, whoever made them.
    public static func events(in timeline: [TimelineEvent], lastSeenAt: Date?, me: UserRef?) -> [TimelineEvent] {
        let ordered = timeline.sorted { $0.createdAt < $1.createdAt }
        guard let lastSeenAt else { return Array(ordered.suffix(firstOpenCount)) }
        return ordered.filter { event in
            guard event.createdAt > lastSeenAt else { return false }
            guard let actor = event.actor, let me else { return true }
            return !LoginMatch.same(actor.login, me.login)
        }
    }

    /// The dot in lists: the item moved after it was last opened. Items never opened get none, or every row would.
    public static func hasChanged(_ item: WorkItem, lastSeenAt: Date?) -> Bool {
        guard let lastSeenAt else { return false }
        return item.updatedAt > lastSeenAt
    }
}
