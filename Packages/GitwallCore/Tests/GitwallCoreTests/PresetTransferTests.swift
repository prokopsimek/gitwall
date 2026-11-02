import Foundation
import Testing
@testable import GitwallCore

@Suite("Preset transfer")
struct PresetTransferTests {
    let reviewID = UUID(uuidString: "6F0C2D6A-1B7E-4C55-9E0A-2D8E4B1F7A10")!
    let bugsID = UUID(uuidString: "0B5E9C3E-77A2-4F1D-8C64-5A9D2E7F3B21")!

    private func decode(_ text: String) -> Result<[Preset], PresetTransferError> {
        PresetTransfer.decode(text)
    }

    private func decoded(_ text: String) throws -> [Preset] {
        try decode(text).get()
    }

    private func failure(_ text: String) -> PresetTransferError? {
        if case .failure(let error) = decode(text) { return error }
        return nil
    }

    // MARK: - Round trip

    @Test("encoding and decoding again gives the same presets and the same text")
    func roundTrip() throws {
        let presets = [
            Preset(
                id: reviewID,
                name: "Čeká na mě · agenti",
                icon: "hand.raised",
                kinds: [.pullRequest, .issue],
                filter: ItemFilter(query: "involves:franta-dxh (label:needs:approval OR (review-requested:@me -is:draft))"),
                sort: .priority
            ),
            Preset(id: bugsID, name: "Bugs", icon: "ladybug", kinds: [.issue], filter: ItemFilter(query: "label:bug"), sort: .oldestCreated),
        ]

        let text = PresetTransfer.encode(presets)
        let again = try decoded(text)

        #expect(again == presets)
        #expect(PresetTransfer.encode(again) == text)
    }

    @Test("the export writes every key of every preset and nothing else")
    func exportShape() throws {
        let preset = Preset(id: reviewID, name: "All open", kinds: [.issue, .pullRequest])
        let data = Data(PresetTransfer.encode([preset]).utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["version", "presets"])
        #expect(object["version"] as? Int == 1)
        let entries = try #require(object["presets"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(Set(entries[0].keys) == ["id", "name", "query", "icon", "sort", "kinds"])
        #expect(entries[0]["id"] as? String == reviewID.uuidString)
        #expect(entries[0]["icon"] as? String == "tray.full")
        #expect(entries[0]["sort"] as? String == "lastActivity")
        // No query is an empty query, and kinds come in a fixed order so a diff of the file stays quiet.
        #expect(entries[0]["query"] as? String == "")
        #expect(entries[0]["kinds"] as? [String] == ["pullRequest", "issue"])
    }

    // MARK: - Reading

    @Test("missing icon, sort and kinds fall back to the defaults")
    func defaults() throws {
        let presets = try decoded(#"{"version": 1, "presets": [{"id": "\#(reviewID)", "name": "Mine", "query": "assignee:@me"}]}"#)

        #expect(presets.count == 1)
        #expect(presets[0].id == reviewID)
        #expect(presets[0].name == "Mine")
        #expect(presets[0].icon == "tray.full")
        #expect(presets[0].sort == .lastActivity)
        #expect(presets[0].kinds == [.pullRequest, .issue])
        #expect(presets[0].filter == ItemFilter(query: "assignee:@me"))
        #expect(presets[0].scopes.isEmpty)
        #expect(presets[0].notifications.isEmpty)
        #expect(!presets[0].showCountInMenuBar)
    }

    @Test("a lowercase id reads as the same UUID")
    func lowercaseID() throws {
        let presets = try decoded(#"[{"id": "\#(reviewID.uuidString.lowercased())", "name": "Mine", "query": ""}]"#)
        #expect(presets.first?.id == reviewID)
    }

    @Test("an empty query means every item, as in the preset editor")
    func emptyQuery() throws {
        let presets = try decoded(#"[{"id": "\#(reviewID)", "name": "Everything", "query": "  "}]"#)
        #expect(presets.first?.filter == ItemFilter.any)
    }

    @Test("a bare list of presets is accepted without the version wrapper")
    func bareArray() throws {
        let presets = try decoded(#"[{"id": "\#(reviewID)", "name": "A", "query": "is:pr"}, {"id": "\#(bugsID)", "name": "B", "query": "label:bug", "kinds": ["issue"], "sort": "newestCreated", "icon": "ladybug"}]"#)

        #expect(presets.map(\.id) == [reviewID, bugsID])
        #expect(presets[1].kinds == [.issue])
        #expect(presets[1].sort == .newestCreated)
        #expect(presets[1].icon == "ladybug")
    }

    @Test("every sort order and kind is spelled as its raw value")
    func rawValues() throws {
        for sort in SortOrder.allCases {
            let presets = try decoded(#"[{"id": "\#(reviewID)", "name": "A", "query": "", "sort": "\#(sort.rawValue)"}]"#)
            #expect(presets.first?.sort == sort)
        }
        for kind in ItemKind.allCases {
            let presets = try decoded(#"[{"id": "\#(reviewID)", "name": "A", "query": "", "kinds": ["\#(kind.rawValue)"]}]"#)
            #expect(presets.first?.kinds == [kind])
        }
    }

    // MARK: - Rejecting

    @Test("text that is not JSON, or no text at all, is rejected")
    func notJSON() {
        #expect(failure("involves:franta-dxh") == .invalidJSON)
        #expect(failure("") == .noText)
        #expect(failure(" \n") == .noText)
    }

    @Test("JSON that is neither the file nor a list is rejected")
    func notAPresetFile() {
        #expect(failure(#""presets""#) == .notAPresetFile)
        #expect(failure("42") == .notAPresetFile)
    }

    @Test("only version 1 is read, and the wrapper must say which version it is")
    func versions() {
        let presets = #"[{"id": "\#(reviewID)", "name": "A", "query": ""}]"#
        #expect(failure(#"{"version": 2, "presets": \#(presets)}"#) == .unsupportedVersion("2"))
        #expect(failure(#"{"version": "1", "presets": \#(presets)}"#) == .unsupportedVersion(#""1""#))
        #expect(failure(#"{"presets": \#(presets)}"#) == .missingVersion)
        #expect(failure(#"{"version": 1}"#) == .missingPresets)
        #expect(failure(#"{"version": 1, "presets": {}}"#) == .notAPresetFile)
    }

    @Test("an unknown key next to the presets is an error, not ignored")
    func unknownTopLevelKey() {
        #expect(failure(#"{"version": 1, "presets": [], "preset": []}"#) == .unknownKeys(["preset"]))
    }

    @Test("an empty list has nothing to paste")
    func emptyList() {
        #expect(failure("[]") == .noPresets)
        #expect(failure(#"{"version": 1, "presets": []}"#) == .noPresets)
    }

    @Test("an unknown key inside a preset names the preset and the key")
    func unknownPresetKey() {
        let error = failure(#"[{"id": "\#(reviewID)", "name": "Mine", "query": "", "sort": "priority", "sortBy": "priority", "Icon": "eye"}]"#)
        #expect(error == .invalidPreset(position: 1, name: "Mine", problem: .unknownKeys(["Icon", "sortBy"])))
    }

    @Test("id, name and query are required")
    func requiredKeys() {
        #expect(failure(#"[{"name": "Mine", "query": ""}]"#) == .invalidPreset(position: 1, name: "Mine", problem: .missingKey("id")))
        #expect(failure(#"[{"id": "\#(reviewID)", "query": ""}]"#) == .invalidPreset(position: 1, name: nil, problem: .missingKey("name")))
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "Mine"}]"#) == .invalidPreset(position: 1, name: "Mine", problem: .missingKey("query")))
    }

    @Test("an id that is not a UUID is rejected")
    func badUUID() {
        let error = failure(#"[{"id": "review-queue", "name": "Mine", "query": ""}]"#)
        #expect(error == .invalidPreset(position: 1, name: "Mine", problem: .invalidID("review-queue")))
    }

    @Test("two presets with one id are rejected, whatever the case of the id")
    func duplicateID() {
        let text = #"[{"id": "\#(reviewID)", "name": "A", "query": ""}, {"id": "\#(bugsID)", "name": "B", "query": ""}, {"id": "\#(reviewID.uuidString.lowercased())", "name": "C", "query": ""}]"#
        #expect(failure(text) == .invalidPreset(position: 3, name: "C", problem: .duplicateID(firstPosition: 1)))
    }

    @Test("an empty or blank name is rejected")
    func emptyName() {
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "", "query": ""}]"#) == .invalidPreset(position: 1, name: nil, problem: .emptyName))
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "   ", "query": ""}]"#) == .invalidPreset(position: 1, name: nil, problem: .emptyName))
    }

    @Test("a query the parser cannot read rejects the paste and says why")
    func invalidQuery() {
        let error = failure(#"[{"id": "\#(reviewID)", "name": "Agents", "query": "involves:franta-dxh (label:x"}]"#)
        #expect(error == .invalidPreset(position: 1, name: "Agents", problem: .invalidQuery(.unclosedParenthesis)))
    }

    @Test("an unknown sort order or kind is rejected, and so is an empty list of kinds")
    func unknownSortAndKinds() {
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "A", "query": "", "sort": "updated"}]"#) == .invalidPreset(position: 1, name: "A", problem: .unknownSort("updated")))
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "A", "query": "", "kinds": ["pr"]}]"#) == .invalidPreset(position: 1, name: "A", problem: .unknownKind("pr")))
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "A", "query": "", "kinds": []}]"#) == .invalidPreset(position: 1, name: "A", problem: .noKinds))
    }

    @Test("a value of the wrong type is rejected")
    func wrongTypes() {
        #expect(failure(#"[{"id": "\#(reviewID)", "name": 5, "query": ""}]"#) == .invalidPreset(position: 1, name: nil, problem: .wrongType(key: "name", expected: .string)))
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "A", "query": null}]"#) == .invalidPreset(position: 1, name: "A", problem: .wrongType(key: "query", expected: .string)))
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "A", "query": "", "kinds": "issue"}]"#) == .invalidPreset(position: 1, name: "A", problem: .wrongType(key: "kinds", expected: .listOfStrings)))
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "A", "query": "", "kinds": [1]}]"#) == .invalidPreset(position: 1, name: "A", problem: .wrongType(key: "kinds", expected: .listOfStrings)))
        #expect(failure(#"["Mine"]"#) == .invalidPreset(position: 1, name: nil, problem: .notAnObject))
    }

    @Test("an icon has to exist; the caller decides which do")
    func icons() {
        let text = #"[{"id": "\#(reviewID)", "name": "A", "query": "", "icon": "hand.raised.fill.nope"}]"#
        #expect((try? PresetTransfer.decode(text).get())?.first?.icon == "hand.raised.fill.nope")
        let rejected = PresetTransfer.decode(text, iconExists: { $0 == "hand.raised" })
        #expect(rejected == .failure(.invalidPreset(position: 1, name: "A", problem: .unknownIcon("hand.raised.fill.nope"))))
        #expect(failure(#"[{"id": "\#(reviewID)", "name": "A", "query": "", "icon": ""}]"#) == .invalidPreset(position: 1, name: "A", problem: .emptyIcon))
    }

    @Test("the first broken preset is reported even when later ones are fine")
    func firstErrorWins() {
        let text = #"[{"id": "\#(reviewID)", "name": "Fine", "query": ""}, {"id": "\#(bugsID)", "name": "Broken", "query": "nope:x"}]"#
        #expect(failure(text) == .invalidPreset(position: 2, name: "Broken", problem: .invalidQuery(.unknownQualifier("nope"))))
    }

    // MARK: - Messages

    @Test("the message names the preset by its position and name")
    func messages() {
        let error = PresetTransferError.invalidPreset(position: 2, name: "Agents", problem: .invalidQuery(.unclosedParenthesis))
        #expect(error.message == "Preset 2 (“Agents”): the query cannot be read. A parenthesis is never closed.")
        let unnamed = PresetTransferError.invalidPreset(position: 1, name: nil, problem: .missingKey("name"))
        #expect(unnamed.message == "Preset 1: “name” is missing.")
        #expect(PresetTransferError.unsupportedVersion("2").message.contains("version 1"))
    }

    // MARK: - Merging

    @Test("a known id replaces name, icon, sort, kinds and query, and keeps the user's own choices")
    func replaceByID() {
        let account = UUID()
        let existing = Preset(
            id: reviewID,
            name: "Old",
            icon: "eye",
            scopes: [PresetScope(accountID: account, repositories: ["acme/app"])],
            kinds: [.pullRequest],
            filter: ItemFilter(relations: [.reviewRequestedFromMe], includeDrafts: false, labelsAny: ["bug"], query: "is:pr"),
            sort: .newestCreated,
            notifications: [.reviewRequested, .ciFailed],
            showCountInMenuBar: true
        )
        let incoming = Preset(id: reviewID, name: "New", icon: "hand.raised", kinds: [.pullRequest, .issue], filter: ItemFilter(query: "label:x"), sort: .priority)

        let merge = PresetTransfer.merge([incoming], into: [existing])

        #expect(merge.added == 0 && merge.replaced == 1 && merge.unchanged == 0)
        let result = merge.presets[0]
        #expect(result.id == reviewID)
        #expect(result.name == "New")
        #expect(result.icon == "hand.raised")
        #expect(result.sort == .priority)
        #expect(result.kinds == [.pullRequest, .issue])
        // A file preset is defined by its query alone, so the structured filters go.
        #expect(result.filter == ItemFilter(query: "label:x"))
        #expect(result.scopes == existing.scopes)
        #expect(result.notifications == existing.notifications)
        #expect(result.showCountInMenuBar)
    }

    @Test("a new id is appended at the end with the defaults for everything the file does not carry")
    func appendNew() {
        let existing = [Preset(name: "All open"), Preset(name: "Mine")]
        let incoming = Preset(id: bugsID, name: "Bugs", icon: "ladybug", kinds: [.issue], filter: ItemFilter(query: "label:bug"), sort: .oldestCreated)

        let merge = PresetTransfer.merge([incoming], into: existing)

        #expect(merge.added == 1 && merge.replaced == 0)
        #expect(merge.presets.map(\.name) == ["All open", "Mine", "Bugs"])
        let added = merge.presets[2]
        #expect(added.id == bugsID)
        #expect(added.scopes.isEmpty)
        #expect(added.notifications.isEmpty)
        #expect(!added.showCountInMenuBar)
    }

    @Test("presets that are not in the paste stay as they are, in their place, and nothing is deleted")
    func othersUntouched() {
        let first = Preset(name: "First", filter: ItemFilter(labelsAny: ["bug"]), notifications: [.merged])
        let middle = Preset(id: reviewID, name: "Middle")
        let last = Preset(name: "Last", scopes: [PresetScope(accountID: UUID())])
        let incoming = [
            Preset(id: bugsID, name: "Bugs", filter: ItemFilter(query: "label:bug")),
            Preset(id: reviewID, name: "Middle renamed", filter: ItemFilter(query: "is:pr")),
        ]

        let merge = PresetTransfer.merge(incoming, into: [first, middle, last])

        #expect(merge.presets.map(\.id) == [first.id, reviewID, last.id, bugsID])
        #expect(merge.presets[0] == first)
        #expect(merge.presets[2] == last)
        #expect(merge.presets[1].name == "Middle renamed")
        #expect(merge.added == 1 && merge.replaced == 1)
    }

    @Test("a preset that already matches the paste counts as unchanged")
    func unchanged() {
        let existing = Preset(id: reviewID, name: "Mine", kinds: [.pullRequest, .issue], filter: ItemFilter(query: "assignee:@me"), notifications: [.newItem])
        let incoming = Preset(id: reviewID, name: "Mine", kinds: [.pullRequest, .issue], filter: ItemFilter(query: "assignee:@me"))

        let merge = PresetTransfer.merge([incoming], into: [existing])

        #expect(merge.added == 0 && merge.replaced == 0 && merge.unchanged == 1)
        #expect(!merge.hasChanges)
        #expect(merge.presets == [existing])
    }

    @Test("the summary counts new and replaced presets, and unchanged ones when there are any")
    func summary() {
        #expect(PresetMerge(presets: [], added: 2, replaced: 1, unchanged: 0).summary == "2 new, 1 replaced")
        #expect(PresetMerge(presets: [], added: 0, replaced: 0, unchanged: 3).summary == "0 new, 0 replaced, 3 unchanged")
    }

    // MARK: - What a copy leaves out

    @Test("a preset defined by its query alone copies without a warning")
    func noWarning() {
        let presets = [
            Preset(name: "All open"),
            Preset(name: "Mine", filter: ItemFilter(query: "assignee:@me"), notifications: [.newItem], showCountInMenuBar: true),
        ]
        #expect(PresetTransfer.copyWarning(for: presets) == nil)
    }

    @Test("scopes and structured filters are named in the warning, preset by preset")
    func warning() throws {
        let presets = [
            Preset(name: "Scoped", scopes: [PresetScope(accountID: UUID())]),
            Preset(name: "Filtered", filter: ItemFilter(includeDrafts: false, query: "is:pr")),
            Preset(name: "Both", scopes: [PresetScope(accountID: UUID())], filter: ItemFilter(relations: [.assignedToMe])),
            Preset(name: "Clean", filter: ItemFilter(query: "label:bug")),
        ]

        let warning = try #require(PresetTransfer.copyWarning(for: presets))

        #expect(warning.contains("“Scoped” (accounts and repositories)"))
        #expect(warning.contains("“Filtered” (filters outside the query)"))
        #expect(warning.contains("“Both” (accounts and repositories, filters outside the query)"))
        #expect(!warning.contains("Clean"))
    }

    @Test("a long warning names five presets and counts the rest")
    func longWarning() throws {
        let presets = (1...7).map { Preset(name: "P\($0)", scopes: [PresetScope(accountID: UUID())]) }
        let warning = try #require(PresetTransfer.copyWarning(for: presets))
        #expect(warning.contains("“P5”"))
        #expect(!warning.contains("“P6”"))
        #expect(warning.contains("and 2 more"))
    }
}
