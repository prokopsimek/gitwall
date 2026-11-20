import Foundation

/// What the search of one preset in one account came to in a sync, the input of ``PresetResult/merged(_:with:at:)``.
public struct PresetOutcome: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The search succeeded. `totalCount` is the provider's count; `isComplete` is false when it stopped early.
        case fetched(itemIDs: [String], totalCount: Int, isComplete: Bool)
        /// The provider refused this one search while the account worked, for example with GraphQL errors in a 200
        /// answer or a rejected query. `code` is the provider's error code.
        case queryFailed(code: String)
        /// The account itself failed: a rejected token, a rate limit, a server error or no connection. Its
        /// ``FetchStatus`` reports that; the preset keeps what it had.
        case accountFailed
    }

    public let presetID: UUID
    public let accountID: UUID
    /// ``Preset/selectionFingerprint`` of the preset as the search ran it.
    public let selection: String
    public let kind: Kind

    public init(preset: Preset, accountID: UUID, kind: Kind) {
        presetID = preset.id
        self.accountID = accountID
        selection = preset.selectionFingerprint
        self.kind = kind
    }
}

extension PresetResult {
    /// The results after a sync: each outcome changes the result of its own (preset, account) pair, and every pair
    /// without an outcome, a preset this sync did not search, stays as it was.
    ///
    /// - A fetched search replaces the pair's result, failure and all.
    /// - A refused search keeps the previous items, fetch time, count and completeness and records the failure. A pair
    ///   without a previous result, or whose result describes another selection, gets an empty result that was never
    ///   fetched, with the failure.
    /// - A failed account leaves the result exactly as it was.
    ///
    /// Of two outcomes for one pair the later one wins. The results come back in the order of preset, then account.
    public static func merged(
        _ previous: [PresetResult], with outcomes: [PresetOutcome], at time: Date
    ) -> [PresetResult] {
        var results = Dictionary(
            previous.map { (Pair($0.presetID, $0.accountID), $0) }, uniquingKeysWith: { _, later in later }
        )
        for outcome in outcomes {
            let pair = Pair(outcome.presetID, outcome.accountID)
            switch outcome.kind {
            case .fetched(let itemIDs, let totalCount, let isComplete):
                results[pair] = PresetResult(
                    presetID: outcome.presetID, accountID: outcome.accountID, itemIDs: itemIDs, fetchedAt: time,
                    totalCount: totalCount, isComplete: isComplete, selection: outcome.selection
                )
            case .queryFailed(let code):
                let failure = PresetQueryFailure(code: code, at: time)
                if var kept = results[pair], kept.selection == outcome.selection {
                    kept.failure = failure
                    results[pair] = kept
                } else {
                    results[pair] = PresetResult(
                        presetID: outcome.presetID, accountID: outcome.accountID, itemIDs: [], fetchedAt: nil,
                        totalCount: 0, isComplete: false, selection: outcome.selection, failure: failure
                    )
                }
            case .accountFailed:
                continue
            }
        }
        return results.values.sorted(by: precedes)
    }

    private struct Pair: Hashable {
        let presetID: UUID
        let accountID: UUID

        init(_ presetID: UUID, _ accountID: UUID) {
            self.presetID = presetID
            self.accountID = accountID
        }
    }
}
