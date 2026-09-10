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
        let seconds = max(0, now.timeIntervalSince(item.updatedAt))
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

    public static func kindSymbol(for kind: ItemKind) -> String {
        switch kind {
        case .pullRequest: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        }
    }
}
