import AppKit
import Foundation
import GitwallAuth
import GitwallCore
@testable import Gitwall
import Testing

/// Edit › Find… in the main window. The window is built but never shown, so nothing takes the focus from other apps.
@Suite("Main window · Find")
@MainActor
struct MainWindowFindTests {
    @Test("Find puts the keyboard in the search field")
    func findFocusesSearch() throws {
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: InMemoryTokenStore(),
            sandbox: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gitwall-find-\(UUID().uuidString)")
        )
        environment.start()
        environment.enterSampleData()
        let controller = MainWindowController(environment: environment)
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        controller.focusSearch(nil)

        let editor = try #require(window.firstResponder as? NSTextView, "first responder: \(String(describing: window.firstResponder))")
        let field = try #require(editor.delegate as? NSTextField)
        #expect((field.placeholderString ?? field.placeholderAttributedString?.string) == MainWindowView.searchPrompt)
    }
}
