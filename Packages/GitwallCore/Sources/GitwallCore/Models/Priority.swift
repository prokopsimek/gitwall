import Foundation

/// How urgent an item is, `P0` (drop everything) to `P3`. Read from a GitHub Projects field named Priority, or from
/// a `p0`–`p3` label when no project gives one. See `docs/adr/0012-priority-comes-from-a-projects-field-then-labels.md`.
public enum Priority: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"

    /// 0 for P0; lower is more urgent.
    public var level: Int {
        switch self {
        case .p0: 0
        case .p1: 1
        case .p2: 2
        case .p3: 3
        }
    }

    /// More urgent sorts first: `.p0 < .p3`.
    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.level < rhs.level }

    /// `P0`–`P3` in any case, alone or followed by a character that is not a letter or digit, so `P1`, `p2`,
    /// `P0 - urgent` and `P1: high` are levels and `P4`, `p2p`, `high` or `priority: low` are not.
    public init?(parsing raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return nil }
        let head = text.prefix(2).uppercased()
        guard let priority = Priority(rawValue: head) else { return nil }
        if let next = text.dropFirst(2).first, next.isLetter || next.isNumber { return nil }
        self = priority
    }

    /// The most urgent level among `values`, or nil when none of them is a level.
    public static func mostUrgent(in values: some Sequence<String>) -> Priority? {
        values.compactMap(Priority.init(parsing:)).min()
    }
}

extension WorkItem {
    /// The project field when a project gives one, otherwise the most urgent `p0`–`p3` label.
    public var priority: Priority? {
        projectPriority ?? Priority.mostUrgent(in: labels.map(\.name))
    }
}
