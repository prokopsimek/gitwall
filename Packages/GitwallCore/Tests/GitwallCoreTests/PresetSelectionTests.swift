import Foundation
import Testing
@testable import GitwallCore

@Suite("Preset selection fingerprint")
struct PresetSelectionTests {
    static let github = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let gitlab = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    /// A preset that uses every part of a selection, with sets and lists of more than one element.
    static func preset() -> Preset {
        Preset(
            name: "Waiting for my review",
            icon: "eye",
            scopes: [
                PresetScope(accountID: github, repositories: ["acme/app", "acme/api", "acme/web", "octo-org/docs"]),
                PresetScope(accountID: gitlab),
            ],
            kinds: [.pullRequest, .issue],
            filter: ItemFilter(
                relations: [.reviewRequestedFromMe, .assignedToMe, .authoredByMe],
                includeDrafts: false,
                labelsAny: ["bug", "urgent", "regression"],
                authorsNone: ["renovate", "dependabot"],
                reviewStates: [.pending, .changesRequested, .none],
                ciStates: [.failure, .running, .none],
                mergeStates: [.clean, .conflict, .unknown],
                query: "is:open label:bug"
            ),
            sort: .lastActivity
        )
    }

    /// An equal set whose iteration order differs from `set`'s. Every set seeds its hash table on its own, so equal
    /// sets can iterate in different orders within one process, and do between launches.
    func reorderedCopy<Element: Hashable>(of set: Set<Element>) -> Set<Element>? {
        for capacity in 1...256 {
            var copy = Set<Element>(minimumCapacity: capacity)
            for element in set.reversed() { copy.insert(element) }
            if Array(copy) != Array(set) { return copy }
        }
        return nil
    }

    @Test("equal presets have one fingerprint whatever order their sets iterate in")
    func setOrderDoesNotMatter() throws {
        let preset = Self.preset()
        var reordered = preset
        reordered.kinds = try #require(reorderedCopy(of: preset.kinds))
        reordered.filter.relations = try #require(reorderedCopy(of: preset.filter.relations))
        reordered.filter.reviewStates = try #require(reorderedCopy(of: preset.filter.reviewStates))
        reordered.filter.ciStates = try #require(reorderedCopy(of: preset.filter.ciStates))
        reordered.filter.mergeStates = try #require(reorderedCopy(of: preset.filter.mergeStates))
        let repositories: Set<String> = try #require(preset.scopes[0].repositories)
        let reorderedRepositories: Set<String> = try #require(reorderedCopy(of: repositories))
        reordered.scopes[0].repositories = reorderedRepositories
        #expect(reordered == preset)

        #expect(reordered.selectionFingerprint == preset.selectionFingerprint)
    }

    @Test("lists whose order selects nothing differently keep the fingerprint in any order")
    func listOrderDoesNotMatter() {
        let preset = Self.preset()
        var reordered = preset
        reordered.scopes.reverse()
        reordered.filter.labelsAny.reverse()
        reordered.filter.authorsNone.reverse()

        #expect(reordered.selectionFingerprint == preset.selectionFingerprint)
    }

    @Test("a preset built twice has the same fingerprint")
    func rebuiltPresetKeepsFingerprint() {
        #expect(Self.preset().selectionFingerprint == Self.preset().selectionFingerprint)
    }

    struct Edit: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let apply: @Sendable (inout Preset) -> Void

        init(_ description: String, _ apply: @escaping @Sendable (inout Preset) -> Void) {
            testDescription = description
            self.apply = apply
        }
    }

    static let selectionEdits: [Edit] = [
        Edit("relations") { $0.filter.relations = [.authoredByMe] },
        Edit("drafts") { $0.filter.includeDrafts = true },
        Edit("labels") { $0.filter.labelsAny.append("p0") },
        Edit("review states") { $0.filter.reviewStates = [.approved] },
        Edit("updated within") { $0.filter.updatedWithinDays = 7 },
        Edit("query") { $0.filter.query = "is:open label:docs" },
        Edit("kinds") { $0.kinds = [.issue] },
        Edit("scopes") { $0.scopes.removeLast() },
        Edit("repositories") { $0.scopes[0].repositories?.insert("octo-org/site") },
        Edit("every repository") { $0.scopes[0].repositories = nil },
        Edit("sort") { $0.sort = .priority },
    ]

    @Test("changing what selects the items changes the fingerprint", arguments: selectionEdits)
    func selectionChangesFingerprint(edit: Edit) {
        let preset = Self.preset()
        var edited = preset
        edit.apply(&edited)

        #expect(edited.selectionFingerprint != preset.selectionFingerprint)
    }

    static let otherEdits: [Edit] = [
        Edit("name") { $0.name = "Reviews" },
        Edit("icon") { $0.icon = "star" },
        Edit("notifications") { $0.notifications = [.newItem, .merged] },
        Edit("menu bar count") { $0.showCountInMenuBar = true },
    ]

    @Test("changing how the preset looks or notifies keeps the fingerprint", arguments: otherEdits)
    func presentationKeepsFingerprint(edit: Edit) {
        let preset = Self.preset()
        var edited = preset
        edit.apply(&edited)

        #expect(edited.selectionFingerprint == preset.selectionFingerprint)
    }
}
