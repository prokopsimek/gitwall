import AppKit
import Foundation
import GitwallAuth
import GitwallCore
@testable import Gitwall
import Testing

/// Copy and paste of presets as JSON (docs/adr/0013). Pasting goes through the one configuration paste of
/// docs/adr/0014, which takes version 1 files as they are. The rules live in `PresetTransfer` and `GitwallFile`; this
/// checks that the app writes what the merge says and reads what it copied. A pasteboard of its own keeps the user's
/// clipboard alone.
@Suite("Preset paste")
@MainActor
struct PresetPasteTests {
    private func environment() -> AppEnvironment {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitwall-paste-\(UUID().uuidString)")
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: InMemoryTokenStore(),
            sandbox: sandbox
        )
        environment.start()
        return environment
    }

    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("gitwall.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    @Test("pasting writes the merge to disk: a known id is replaced in place, a new one appended")
    func pasteWrites() throws {
        let environment = environment()
        let kept = Preset(name: "Kept", notifications: [.merged])
        let replaced = Preset(name: "Old name", notifications: [.reviewRequested], showCountInMenuBar: true)
        environment.addPreset(kept)
        environment.addPreset(replaced)
        let before = environment.config.presets.map(\.id)

        let incoming = [
            Preset(id: replaced.id, name: "New name", icon: "eye", filter: ItemFilter(query: "review-requested:@me")),
            Preset(name: "Pasted", filter: ItemFilter(query: "label:bug")),
        ]
        let file = GitwallFile(presets: incoming)
        #expect(environment.pastePreview(file).summary == "1 new preset, 1 preset replaced")
        environment.pasteConfiguration(file)

        let stored = try #require(try environment.configStore?.load())
        #expect(stored.presets.map(\.id) == before + [incoming[1].id])
        let updated = try #require(stored.preset(id: replaced.id))
        #expect(updated.name == "New name")
        #expect(updated.notifications == [.reviewRequested])
        #expect(updated.showCountInMenuBar)
        #expect(stored.preset(id: kept.id) == kept)
    }

    @Test("what Copy as JSON puts on the pasteboard pastes back without a change")
    func copyThenPaste() throws {
        let environment = environment()
        let preset = Preset(name: "Agents", icon: "person.2", kinds: [.pullRequest, .issue], filter: ItemFilter(query: "involves:franta-dxh"), sort: .priority)
        environment.addPreset(preset)

        try withPasteboard { pasteboard in
            #expect(environment.copyPresetsAsJSON([preset], to: pasteboard) == nil)
            let file = try environment.configurationOnPasteboard(pasteboard).get()
            #expect(file.presets.map(\.id) == [preset.id])
            #expect(!environment.pastePreview(file).hasChanges)
        }
    }

    @Test("an icon that is not an SF Symbol is refused before anything is written")
    func unknownIcon() {
        let environment = environment()
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(#"[{"id": "\#(UUID())", "name": "A", "query": "", "icon": "no.such.symbol"}]"#, forType: .string)
            let result = environment.configurationOnPasteboard(pasteboard)
            #expect(result == .failure(.presetFile(.invalidPreset(position: 1, name: "A", problem: .unknownIcon("no.such.symbol")))))
        }
    }

    @Test("a version 1 file and a bare list, as older versions copy them, paste their presets")
    func versionOneFile() throws {
        let environment = environment()
        let bugs = Preset(name: "Bugs", kinds: [.issue], filter: ItemFilter(query: "label:bug"), sort: .priority)
        let mine = UUID()

        try withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(PresetTransfer.encode([bugs]), forType: .string)
            let file = try environment.configurationOnPasteboard(pasteboard).get()
            #expect(file.presets.map(\.id) == [bugs.id])
            #expect(file.walls.isEmpty)
            environment.pasteConfiguration(file)

            pasteboard.clearContents()
            pasteboard.setString(#"[{"id": "\#(mine)", "name": "Mine", "query": "author:@me"}]"#, forType: .string)
            environment.pasteConfiguration(try environment.configurationOnPasteboard(pasteboard).get())
        }

        let stored = try #require(try environment.configStore?.load())
        #expect(stored.presets.map(\.id).suffix(2) == [bugs.id, mine])
        #expect(stored.preset(id: bugs.id)?.filter.query == "label:bug")
        #expect(stored.walls.isEmpty)
    }
}
