import Foundation
import GitwallCore
import OSLog
import UserNotifications

private let log = Logger(subsystem: "cz.prokopsimek.gitwall", category: "notifications")

/// Turns routed snapshot changes into macOS notifications.
@MainActor
final class NotificationDispatcher {
    nonisolated static let itemIDKey = "itemID"

    private let center = UNUserNotificationCenter.current()
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init() {
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    func requestAuthorizationIfNeeded() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshAuthorizationStatus()
    }

    func deliver(_ routed: [RoutedNotification], capabilities: [ProviderKind: any GitProvider]) async {
        guard !routed.isEmpty else { return }
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        // Cap bursts: after a long offline period a single sync can carry dozens of changes.
        let batch = routed.prefix(10)
        for entry in batch {
            let item = entry.change.item
            let content = UNMutableNotificationContent()
            content.title = title(for: entry.change.event, item: item)
            content.subtitle = "\(item.repoFullName) #\(item.number)"
            content.body = item.title
            content.sound = .default
            content.threadIdentifier = entry.preset.id.uuidString
            content.userInfo = [Self.itemIDKey: item.id]
            let request = UNNotificationRequest(identifier: "\(item.id)-\(entry.change.event.rawValue)", content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                log.error("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if routed.count > batch.count {
            let content = UNMutableNotificationContent()
            content.title = "Gitwall"
            content.body = "\(routed.count - batch.count) more changes since the last sync."
            try? await center.add(UNNotificationRequest(identifier: "gitwall-overflow-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
        }
    }

    private func title(for event: NotificationEvent, item: WorkItem) -> String {
        let kind = item.kind == .pullRequest ? "Pull request" : "Issue"
        switch event {
        case .newItem: return "New \(kind.lowercased())"
        case .reviewRequested: return "Review requested"
        case .approved: return "\(kind) approved"
        case .changesRequested: return "Changes requested"
        case .ciFailed: return "Checks failed"
        case .merged: return "\(kind) merged"
        case .closed: return "\(kind) closed or merged"
        }
    }
}
