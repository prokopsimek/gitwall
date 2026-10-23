import Foundation
import GitwallCore

/// Pure formatting helpers shared by the popover and the widget.
public enum ItemPresentation {
    public enum Tone: Sendable, Hashable {
        case positive, negative, warning, neutral
    }

    public struct Badge: Hashable, Sendable, Identifiable {
        public var id: String { symbol }
        public let symbol: String
        public let text: String
        public let tone: Tone
    }

    /// "mcp-gateway #42"
    public static func repoLabel(for item: WorkItem) -> String {
        let name = item.repoFullName.split(separator: "/").last.map(String.init) ?? item.repoFullName
        return "\(name) #\(item.number)"
    }

    /// Compact relative age: now, 5m, 3h, 2d, 4w.
    public static func age(of item: WorkItem, now: Date = Date()) -> String {
        compactAge(since: item.updatedAt, now: now)
    }

    /// Compact relative age of any date: now, 5m, 3h, 2d, 4w.
    public static func compactAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (7 * 86_400)))w"
        }
    }

    public static func badges(for item: WorkItem) -> [Badge] {
        guard item.kind == .pullRequest else { return [] }
        var badges: [Badge] = []
        if item.isDraft {
            badges.append(Badge(symbol: "pencil.circle", text: "Draft", tone: .neutral))
        }
        switch item.reviewState ?? .none {
        case .approved: badges.append(Badge(symbol: "checkmark.circle.fill", text: "Approved", tone: .positive))
        case .changesRequested: badges.append(Badge(symbol: "xmark.circle", text: "Changes requested", tone: .negative))
        case .pending: badges.append(Badge(symbol: "clock", text: "Review pending", tone: .warning))
        case .none: break
        }
        switch item.ciState ?? .none {
        case .success: badges.append(Badge(symbol: "checkmark.circle", text: "Checks passed", tone: .positive))
        case .failure: badges.append(Badge(symbol: "exclamationmark.triangle", text: "Checks failed", tone: .negative))
        case .running: badges.append(Badge(symbol: "circle.dotted", text: "Checks running", tone: .warning))
        case .none: break
        }
        if item.mergeState == .conflict {
            badges.append(Badge(symbol: "arrow.triangle.merge", text: "Merge conflict", tone: .negative))
        }
        return badges
    }

    public struct PriorityBadge: Hashable, Sendable {
        /// "P0" to "P3".
        public let text: String
        /// Tooltip and accessibility label: the level and where it came from.
        public let help: String
        public let tone: Tone
    }

    /// The small capsule before the title; nil for an item without a priority. Only P0 and P1 get a colour, so the
    /// list stays calm when most items carry one.
    public static func priorityBadge(for item: WorkItem) -> PriorityBadge? {
        guard let priority = item.priority else { return nil }
        let source = item.projectPriority != nil ? "set in a project" : "from a label"
        let tone: Tone = switch priority {
        case .p0: .negative
        case .p1: .warning
        case .p2, .p3: .neutral
        }
        return PriorityBadge(text: priority.rawValue, help: "Priority \(priority.rawValue), \(source)", tone: tone)
    }

    /// Labels for the detail line. A `p1` label that already shows as the priority capsule is left out; one that
    /// disagrees with a project's value stays, so the conflict remains visible.
    public static func displayedLabels(for item: WorkItem) -> [Label] {
        guard item.projectPriority == nil else { return item.labels }
        return item.labels.filter { Priority(parsing: $0.name) == nil }
    }

    public static func kindSymbol(for kind: ItemKind) -> String {
        switch kind {
        case .pullRequest: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        }
    }
}
