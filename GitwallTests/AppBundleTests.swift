import AppKit
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

    @Test("widget kinds are stable so widgets on desktops keep working across updates")
    func widgetKind() {
        #expect(AppGroup.widgetKinds == ["cz.prokopsimek.gitwall.counter", "cz.prokopsimek.gitwall.list", "cz.prokopsimek.gitwall.board", "cz.prokopsimek.gitwall.wideboard"])
    }

    @Test("the test host never touches the real App Group")
    @MainActor
    func hostUsesThrowawayContainer() throws {
        // AppDelegate swaps in a temporary container when XCTest hosts the app; the real one belongs to the user.
        let real = AppGroup.containerURL()?.standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let used = try #require(Self.hostContainer())
        #expect(used.standardizedFileURL != real)
        #expect(used.standardizedFileURL.path.hasPrefix(temp))
    }

    /// The container the running app host chose, read through the Objective-C runtime so this bundle does not
    /// need to link the app module.
    @MainActor
    private static func hostContainer() -> URL? {
        guard let delegate = NSApplication.shared.delegate as? NSObject,
              let environment = Mirror(reflecting: delegate).children.first(where: { $0.label == "environment" })?.value
        else { return nil }
        return Mirror(reflecting: environment).children.first(where: { $0.label == "container" })?.value as? URL
    }

    @Test("starts as a regular app so the Dock shows the real icon; agent mode is a runtime switch")
    func isRegularApp() throws {
        let value = hostInfo["LSUIElement"]
        #expect(value == nil || (value as? NSNumber)?.boolValue == false)
    }
}
