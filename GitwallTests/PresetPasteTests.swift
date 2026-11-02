import AppKit
import Foundation
import GitwallAuth
import GitwallCore
@testable import Gitwall
import Testing

/// Copy and paste of presets as JSON (docs/adr/0013). The rules live in `PresetTransfer`; this checks that the app
/// writes what the merge says and reads what it copied. A pasteboard of its own keeps the user's clipboard alone.
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
        #expect(environment.pastePreview(incoming).summary == "1 new, 1 replaced")
        environment.pastePresets(incoming)

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
            let incoming = try environment.presetsOnPasteboard(pasteboard).get()
            #expect(incoming.map(\.id) == [preset.id])
            #expect(!environment.pastePreview(incoming).hasChanges)
        }
    }

    @Test("an icon that is not an SF Symbol is refused before anything is written")
    func unknownIcon() {
        let environment = environment()
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(#"[{"id": "\#(UUID())", "name": "A", "query": "", "icon": "no.such.symbol"}]"#, forType: .string)
            let result = environment.presetsOnPasteboard(pasteboard)
            #expect(result == .failure(.invalidPreset(position: 1, name: "A", problem: .unknownIcon("no.such.symbol"))))
        }
    }
}
