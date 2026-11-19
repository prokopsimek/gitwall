import Foundation
import GitwallCore
import SwiftUI

/// The words for a preset's count, from ``PresetCountDisplay``: what the popover, the main window's sidebar,
/// Settings › Presets and onboarding show beside a preset's name, what the menu bar shows, and what a widget or a wall
/// tile shows in place of a list it has nothing for yet. Strings go through the String Catalog.
public struct PresetCountPresentation: Equatable, Sendable {
    /// What a list of the preset shows instead of its items, because it has none fetched yet.
    public enum Placeholder: Equatable, Sendable {
        /// The preset's query failed before it was ever fetched.
        case queryFailed
        /// Nothing of the preset was fetched yet.
        case waitingForSync
    }

    /// "12", "1000+" above the provider's cap, "–" for a preset never fetched, or "Query failed" when its query failed
    /// before it was.
    public let text: String
    /// The tooltip: "Updated 5 min ago", "Not fetched yet", or "Query failed" with the time of the last result.
    public let help: String
    /// A query of the preset failed; ``text`` still counts the last result when there is one.
    public let isFailure: Bool
    /// Nil while the preset has items to show, also after a failed query.
    public let placeholder: Placeholder?

    /// A list that shows the last items of a failed query says above them that the query failed.
    public var showsFailureNotice: Bool { isFailure && placeholder == nil }

    public init(_ display: PresetCountDisplay, now: Date) {
        isFailure = display.failure != nil
        let age = display.fetchedAt.map { SyncStatus.age(since: $0, now: now) }
        if let count = display.count {
            text = Self.text(count: count, isCapped: display.isCapped)
            placeholder = nil
        } else if isFailure {
            text = String(localized: "Query failed")
            placeholder = .queryFailed
        } else {
            text = "–"
            placeholder = .waitingForSync
        }
        if isFailure {
            help = age.map { String(localized: "Query failed · updated \($0)") } ?? String(localized: "Query failed")
        } else {
            help = age.map { String(localized: "Updated \($0)") } ?? String(localized: "Not fetched yet")
        }
    }

    /// The count beside the menu bar icon: nothing for no items or for a preset never fetched.
    public static func menuBarText(_ display: PresetCountDisplay) -> String {
        guard let count = display.count, count > 0 else { return "" }
        return text(count: count, isCapped: display.isCapped)
    }

    /// When the items a window or a widget shows for the preset were fetched: the preset's own time, else the
    /// snapshot's, but none while the preset waits for its first fetch.
    public static func fetchedAt(_ display: PresetCountDisplay, snapshotFetchedAt: Date?) -> Date? {
        display.fetchedAt ?? (display.isWaitingForSync ? nil : snapshotFetchedAt)
    }

    /// The number without grouping, "1000+" as GitHub writes its cap, whatever the locale.
    private static func text(count: Int, isCapped: Bool) -> String {
        isCapped ? String(localized: "\(String(count))+") : String(count)
    }
}

/// A preset's count beside its name: ``PresetCountPresentation/text``, a warning symbol after a failed query, and the
/// tooltip. The caller sets the font and the colour.
public struct PresetCountLabel: View {
    let presentation: PresetCountPresentation

    public init(_ presentation: PresetCountPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        HStack(spacing: 3) {
            if presentation.isFailure {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(presentation.text)
        }
        .help(presentation.help)
    }
}
