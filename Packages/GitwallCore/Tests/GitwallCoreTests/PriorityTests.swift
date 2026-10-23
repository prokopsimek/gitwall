import Foundation
import Testing
@testable import GitwallCore

@Suite("Priority")
struct PriorityTests {
    private func item(labels: [String] = [], projectPriority: Priority? = nil) -> WorkItem {
        WorkItem(
            accountID: UUID(), kind: .issue, repoFullName: "acme/app", number: 1, title: "Thing",
            url: URL(string: "https://example.com/1")!, author: UserRef(login: "someone"),
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            labels: labels.map { Label(name: $0) }, projectPriority: projectPriority
        )
    }

    @Test("P0 to P3 in any case, alone or followed by a separator", arguments: [
        ("P0", Priority.p0), ("p1", .p1), (" P2 ", .p2), ("p3", .p3),
        ("P0 - urgent", .p0), ("P1: high", .p1), ("P2/backlog", .p2), ("p3 🧊", .p3),
    ])
    func levels(raw: String, expected: Priority) {
        #expect(Priority(parsing: raw) == expected)
    }

    @Test("anything else is not a level", arguments: [
        "", "P", "P4", "P10", "p2p", "P1x", "high", "Priority: Low", "high-priority", "priority: p1", "🔥 P0",
    ])
    func notLevels(raw: String) {
        #expect(Priority(parsing: raw) == nil)
    }

    @Test("more urgent compares lower")
    func ordering() {
        #expect(Priority.p0 < .p1)
        #expect(Priority.allCases.sorted() == [.p0, .p1, .p2, .p3])
        #expect(Priority.mostUrgent(in: ["p3", "bug", "P1", "p2"]) == .p1)
        #expect(Priority.mostUrgent(in: ["bug", "frontend"]) == nil)
    }

    @Test("an item takes the project value first, then its most urgent label")
    func itemPriority() {
        #expect(item().priority == nil)
        #expect(item(labels: ["bug", "p2"]).priority == .p2)
        #expect(item(labels: ["p3", "P1"]).priority == .p1)
        #expect(item(labels: ["p0"], projectPriority: .p2).priority == .p2)
        #expect(item(projectPriority: .p3).priority == .p3)
    }

    @Test("a snapshot written before priorities existed still loads, without project values")
    func olderSnapshot() throws {
        let snapshot = try SnapshotCoding.decode(Snapshot.self, from: Fixtures.data("snapshot.json"))
        #expect(snapshot.items.allSatisfy { $0.projectPriority == nil && $0.nodeID == nil })
        #expect(snapshot.accountStatus.values.allSatisfy { $0.projectAccess == nil })
    }

    @Test("project values, node ids and project access survive a round trip")
    func roundTrip() throws {
        var item = item(labels: ["p3"], projectPriority: .p0)
        item.nodeID = "I_kwDOAbc"
        let snapshot = Snapshot(
            fetchedAt: Date(timeIntervalSince1970: 0), items: [item],
            accountStatus: [item.accountID: FetchStatus(state: .ok, projectAccess: .denied)]
        )
        let decoded = try SnapshotCoding.decode(Snapshot.self, from: SnapshotCoding.encode(snapshot))
        #expect(decoded == snapshot)
        #expect(String(decoding: try SnapshotCoding.encode(item), as: UTF8.self).contains(#""projectPriority" : "P0""#))
    }
}
