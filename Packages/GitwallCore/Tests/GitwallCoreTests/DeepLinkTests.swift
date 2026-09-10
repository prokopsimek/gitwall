import Foundation
import Testing
@testable import GitwallCore

@Suite("DeepLink")
struct DeepLinkTests {
    @Test("item link round-trips an id containing slashes and hashes")
    func itemRoundTrip() throws {
        let id = "8A2F7C1E-1111-2222-3333-444455556666/dxheroes/mcp-gateway#42/pullRequest"
        let url = DeepLink.item(id: id).url
        #expect(url.scheme == "gitwall")
        #expect(url.host == "item")
        #expect(DeepLink(url: url) == .item(id: id))
    }

    @Test("view link round-trips a UUID")
    func viewRoundTrip() throws {
        let viewID = UUID()
        let url = DeepLink.view(id: viewID).url
        #expect(url.host == "view")
        #expect(DeepLink(url: url) == .view(id: viewID))
    }

    @Test("refresh link has no parameters")
    func refresh() throws {
        let url = DeepLink.refresh.url
        #expect(url.absoluteString == "gitwall://refresh")
        #expect(DeepLink(url: url) == .refresh)
    }

    @Test("settings link carries an optional tab")
    func settings() throws {
        #expect(DeepLink.settings(tab: nil).url.absoluteString == "gitwall://settings")
        #expect(DeepLink(url: DeepLink.settings(tab: "presets").url) == .settings(tab: "presets"))
        #expect(DeepLink(url: URL(string: "gitwall://settings?tab=")!) == .settings(tab: nil))
    }

    @Test("foreign scheme is rejected")
    func foreignScheme() {
        #expect(DeepLink(url: URL(string: "https://item?id=x")!) == nil)
    }

    @Test("unknown host is rejected")
    func unknownHost() {
        #expect(DeepLink(url: URL(string: "gitwall://nonsense")!) == nil)
    }

    @Test("item without id is rejected")
    func itemWithoutID() {
        #expect(DeepLink(url: URL(string: "gitwall://item")!) == nil)
        #expect(DeepLink(url: URL(string: "gitwall://item?id=")!) == nil)
    }

    @Test("view with malformed UUID is rejected")
    func malformedView() {
        #expect(DeepLink(url: URL(string: "gitwall://view?id=not-a-uuid")!) == nil)
    }
}
