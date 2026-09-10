import Foundation
import GitwallCore
import Testing

/// Guards the generated Info.plist: the widget relies on the `gitwall` scheme being registered.
@Suite("App bundle")
struct AppBundleTests {
    private var hostInfo: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    @Test("registers the gitwall URL scheme")
    func registersURLScheme() throws {
        let types = try #require(hostInfo["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(AppGroup.urlScheme))
    }

    @Test("starts as a regular app so the Dock shows the real icon; agent mode is a runtime switch")
    func isRegularApp() throws {
        let value = hostInfo["LSUIElement"]
        #expect(value == nil || (value as? NSNumber)?.boolValue == false)
    }
}
