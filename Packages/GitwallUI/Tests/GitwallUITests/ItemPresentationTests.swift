import Foundation
import GitwallCore
import Testing
@testable import GitwallUI

@Suite("ItemPresentation")
struct ItemPresentationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(kind: ItemKind = .pullRequest, ageSeconds: TimeInterval = 90, reviewState: ReviewState? = nil, ciState: CIState? = nil, mergeState: MergeState? = nil, isDraft: Bool = false) -> WorkItem {
        WorkItem(accountID: UUID(), kind: kind, repoFullName: "dxheroes/mcp-gateway", number: 42, title: "T",
                 url: URL(string: "https://example.com")!, author: UserRef(login: "a"),
                 createdAt: now, updatedAt: now.addingTimeInterval(-ageSeconds), isDraft: isDraft,
                 reviewState: reviewState, ciState: ciState, mergeState: mergeState)
    }

    @Test("repository is shortened to its name with the number")
    func repoLabel() {
        #expect(ItemPresentation.repoLabel(for: item()) == "mcp-gateway #42")
    }

    @Test("relative age is compact")
    func age() {
        #expect(ItemPresentation.age(of: item(ageSeconds: 30), now: now) == "now")
        #expect(ItemPresentation.age(of: item(ageSeconds: 5 * 60), now: now) == "5m")
        #expect(ItemPresentation.age(of: item(ageSeconds: 3 * 3600), now: now) == "3h")
        #expect(ItemPresentation.age(of: item(ageSeconds: 2 * 86_400), now: now) == "2d")
        #expect(ItemPresentation.age(of: item(ageSeconds: 30 * 86_400), now: now) == "4w")
    }

    @Test("compact age works for arbitrary dates")
    func compactAge() {
        #expect(ItemPresentation.compactAge(since: now.addingTimeInterval(-1196), now: now) == "19m")
        #expect(ItemPresentation.compactAge(since: now.addingTimeInterval(60), now: now) == "now")
    }

    @Test("status badges list draft, review, CI and merge problems in that order")
    func badges() {
        let pr = item(reviewState: .changesRequested, ciState: .failure, mergeState: .conflict, isDraft: true)
        #expect(ItemPresentation.badges(for: pr).map(\.symbol) == ["pencil.circle", "xmark.circle", "exclamationmark.triangle", "arrow.triangle.merge"])
        let clean = item(reviewState: .approved, ciState: .success, mergeState: .clean)
        #expect(ItemPresentation.badges(for: clean).map(\.symbol) == ["checkmark.circle.fill", "checkmark.circle"])
        #expect(ItemPresentation.badges(for: item(kind: .issue)).isEmpty)
    }

    @Test("badges carry accessibility text")
    func badgeText() {
        let pr = item(reviewState: .pending, ciState: .running)
        #expect(ItemPresentation.badges(for: pr).map(\.text) == ["Review pending", "Checks running"])
    }
}
