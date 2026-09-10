import Foundation

/// Applies presets to snapshot items. Pure functions, shared by the app and the widget so both agree.
public enum FilterEngine {
    public static func items(matching preset: Preset, in items: [WorkItem], accounts: [Account], now: Date) -> [WorkItem] {
        let identities = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.me) })
        let matching = items.filter { matches($0, preset: preset, identities: identities, now: now) }
        return sort(matching, by: preset.sort)
    }

    public static func counts(for presets: [Preset], in items: [WorkItem], accounts: [Account], now: Date) -> [UUID: Int] {
        let identities = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.me) })
        var counts: [UUID: Int] = [:]
        for preset in presets {
            counts[preset.id] = items.reduce(into: 0) { partial, item in
                if matches(item, preset: preset, identities: identities, now: now) { partial += 1 }
            }
        }
        return counts
    }

    public static func sort(_ items: [WorkItem], by order: SortOrder) -> [WorkItem] {
        items.sorted { lhs, rhs in
            switch order {
            case .lastActivity:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            case .newestCreated:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .oldestCreated:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Matching

    static func matches(_ item: WorkItem, preset: Preset, identities: [UUID: UserRef?], now: Date) -> Bool {
        guard preset.kinds.contains(item.kind) else { return false }
        guard inScope(item, scopes: preset.scopes) else { return false }
        return matches(item, filter: preset.filter, me: identities[item.accountID] ?? nil, now: now)
    }

    private static func inScope(_ item: WorkItem, scopes: [PresetScope]) -> Bool {
        guard !scopes.isEmpty else { return true }
        return scopes.contains { scope in
            guard scope.accountID == item.accountID else { return false }
            guard let repositories = scope.repositories else { return true }
            return repositories.contains(item.repoFullName)
        }
    }

    static func matches(_ item: WorkItem, filter: ItemFilter, me: UserRef?, now: Date) -> Bool {
        if !filter.relations.isEmpty {
            guard let me, filter.relations.contains(where: { relation(relationKind: $0, item: item, me: me) }) else {
                return false
            }
        }
        if !filter.includeDrafts, item.isDraft { return false }

        let labels = Set(item.labels.map { $0.name.lowercased() })
        if !filter.labelsAny.isEmpty, filter.labelsAny.allSatisfy({ !labels.contains($0.lowercased()) }) { return false }
        if filter.labelsNone.contains(where: { labels.contains($0.lowercased()) }) { return false }

        if item.kind == .pullRequest {
            if !filter.reviewStates.isEmpty, !filter.reviewStates.contains(item.reviewState ?? .none) { return false }
            if !filter.ciStates.isEmpty, !filter.ciStates.contains(item.ciState ?? .none) { return false }
            if !filter.mergeStates.isEmpty, !filter.mergeStates.contains(item.mergeState ?? .unknown) { return false }
        }

        if let days = filter.updatedWithinDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            if item.updatedAt < cutoff { return false }
        }

        if let milestone = filter.milestone?.trimmingCharacters(in: .whitespaces), !milestone.isEmpty {
            guard let itemMilestone = item.milestone, itemMilestone.caseInsensitiveCompare(milestone) == .orderedSame else {
                return false
            }
        }

        if let text = filter.text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty {
            let haystacks = [item.title.lowercased(), item.repoFullName.lowercased(), "#\(item.number)"]
            if !haystacks.contains(where: { $0.contains(text) }) { return false }
        }

        return true
    }

    private static func relation(relationKind: Relation, item: WorkItem, me: UserRef) -> Bool {
        func isMe(_ user: UserRef) -> Bool { user.login.caseInsensitiveCompare(me.login) == .orderedSame }
        switch relationKind {
        case .authoredByMe: return isMe(item.author)
        case .reviewRequestedFromMe: return item.requestedReviewers.contains(where: isMe)
        case .assignedToMe: return item.assignees.contains(where: isMe)
        }
    }
}
