import Foundation
import Testing
@testable import GitwallCore

@Suite("Merging preset results")
struct PresetResultMergeTests {
    /// Two accounts, `work` sorting before `personal`, so an expected order can be written down.
    static let work = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let personal = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    let review = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Waiting for my review",
                        filter: ItemFilter(relations: [.reviewRequestedFromMe], query: "is:open"))
    let blockers = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, name: "Release blockers",
                          kinds: [.issue], filter: ItemFilter(labelsAny: ["blocker"]))
    let earlier = Date(timeIntervalSince1970: 1_800_000_000)
    let now = Date(timeIntervalSince1970: 1_800_000_300)

    func result(_ preset: Preset, _ account: UUID, items: [String], failure: PresetQueryFailure? = nil) -> PresetResult {
        PresetResult(presetID: preset.id, accountID: account, itemIDs: items, fetchedAt: earlier,
                     totalCount: items.count, isComplete: true, selection: preset.selectionFingerprint, failure: failure)
    }

    @Test("a fetched search replaces the pair's previous result and clears its failure")
    func fetchedReplaces() {
        let previous = [result(review, Self.work, items: ["1", "2"],
                               failure: PresetQueryFailure(code: "validation", at: earlier))]

        let merged = PresetResult.merged(previous, with: [
            PresetOutcome(preset: review, accountID: Self.work,
                          kind: .fetched(itemIDs: ["3"], totalCount: 1_500, isComplete: false)),
        ], at: now)

        #expect(merged == [
            PresetResult(presetID: review.id, accountID: Self.work, itemIDs: ["3"], fetchedAt: now, totalCount: 1_500,
                         isComplete: false, selection: review.selectionFingerprint),
        ])
    }

    @Test("a refused search keeps the previous items, time, count and completeness and records the failure")
    func queryFailedKeepsPrevious() {
        let previous = [result(review, Self.work, items: ["1", "2"])]

        let merged = PresetResult.merged(previous, with: [
            PresetOutcome(preset: review, accountID: Self.work, kind: .queryFailed(code: "validation")),
        ], at: now)

        #expect(merged == [
            PresetResult(presetID: review.id, accountID: Self.work, itemIDs: ["1", "2"], fetchedAt: earlier,
                         totalCount: 2, isComplete: true, selection: review.selectionFingerprint,
                         failure: PresetQueryFailure(code: "validation", at: now)),
        ])
    }

    @Test("a refused search without a previous result leaves the pair never fetched, with the failure")
    func queryFailedWithoutPrevious() {
        let merged = PresetResult.merged([], with: [
            PresetOutcome(preset: review, accountID: Self.work, kind: .queryFailed(code: "validation")),
        ], at: now)

        #expect(merged == [
            PresetResult(presetID: review.id, accountID: Self.work, itemIDs: [], fetchedAt: nil, totalCount: 0,
                         isComplete: false, selection: review.selectionFingerprint,
                         failure: PresetQueryFailure(code: "validation", at: now)),
        ])
    }

    @Test("a refused search over a result of another selection treats the pair as having none")
    func queryFailedOverOtherSelection() {
        var edited = review
        edited.filter.query = "is:open label:docs"
        let previous = [result(review, Self.work, items: ["1", "2"])]

        let merged = PresetResult.merged(previous, with: [
            PresetOutcome(preset: edited, accountID: Self.work, kind: .queryFailed(code: "validation")),
        ], at: now)

        #expect(merged == [
            PresetResult(presetID: review.id, accountID: Self.work, itemIDs: [], fetchedAt: nil, totalCount: 0,
                         isComplete: false, selection: edited.selectionFingerprint,
                         failure: PresetQueryFailure(code: "validation", at: now)),
        ])
    }

    @Test("a failed account leaves the previous result exactly as it was and records nothing on the preset")
    func accountFailedKeepsPrevious() {
        let previous = [result(review, Self.work, items: ["1", "2"])]

        let merged = PresetResult.merged(previous, with: [
            PresetOutcome(preset: review, accountID: Self.work, kind: .accountFailed),
        ], at: now)

        #expect(merged == previous)
    }

    @Test("a failed account without a previous result adds none")
    func accountFailedWithoutPrevious() {
        let merged = PresetResult.merged([], with: [
            PresetOutcome(preset: review, accountID: Self.work, kind: .accountFailed),
        ], at: now)

        #expect(merged.isEmpty)
    }

    @Test("a pair this sync did not search keeps its result")
    func pairWithoutOutcomeIsKept() {
        let kept = result(blockers, Self.work, items: ["7"], failure: PresetQueryFailure(code: "validation", at: earlier))
        let previous = [result(review, Self.work, items: ["1"]), kept]

        let merged = PresetResult.merged(previous, with: [
            PresetOutcome(preset: review, accountID: Self.work,
                          kind: .fetched(itemIDs: ["2"], totalCount: 1, isComplete: true)),
        ], at: now)

        #expect(merged == [
            PresetResult(presetID: review.id, accountID: Self.work, itemIDs: ["2"], fetchedAt: now, totalCount: 1,
                         isComplete: true, selection: review.selectionFingerprint),
            kept,
        ])
    }

    @Test("two accounts of one preset are separate pairs")
    func accountsAreSeparatePairs() {
        let previous = [result(review, Self.personal, items: ["p1"]), result(review, Self.work, items: ["w1"])]

        let merged = PresetResult.merged(previous, with: [
            PresetOutcome(preset: review, accountID: Self.work,
                          kind: .fetched(itemIDs: ["w2"], totalCount: 1, isComplete: true)),
            PresetOutcome(preset: review, accountID: Self.personal, kind: .queryFailed(code: "validation")),
        ], at: now)

        #expect(merged == [
            PresetResult(presetID: review.id, accountID: Self.work, itemIDs: ["w2"], fetchedAt: now, totalCount: 1,
                         isComplete: true, selection: review.selectionFingerprint),
            PresetResult(presetID: review.id, accountID: Self.personal, itemIDs: ["p1"], fetchedAt: earlier,
                         totalCount: 1, isComplete: true, selection: review.selectionFingerprint,
                         failure: PresetQueryFailure(code: "validation", at: now)),
        ])
    }
}
