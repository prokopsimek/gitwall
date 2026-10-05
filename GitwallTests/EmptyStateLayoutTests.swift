import AppKit
import Foundation
import GitwallAuth
import GitwallCore
import SwiftUI
@testable import Gitwall
import Testing

/// A window asks its content for the smallest size it can live with by offering it no room at all. A message that
/// answers with the height it needs at that width wraps one letter per line: with a two-sentence message the main
/// window laid its split view out 2031 points tall inside a 760-point window, so the sidebar, the header and the
/// status bar were off both ends and only the middle of the empty state was left (macOS 27).
@Suite("Empty state layout")
@MainActor
struct EmptyStateLayoutTests {
    /// The main window is at least 460 points tall; its header and status bar take about 70 of them.
    private let roomInTheSmallestWindow: CGFloat = 380

    private func environment() -> AppEnvironment {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitwall-empty-\(UUID().uuidString)")
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: InMemoryTokenStore(),
            sandbox: sandbox
        )
        environment.start()
        return environment
    }

    private var idle: Account {
        Account(
            kind: .github,
            baseURL: URL(string: "https://github.com")!,
            displayName: "GitHub (prokopsimek)",
            me: UserRef(login: "prokopsimek")
        )
    }

    private func smallestHeight(of kind: EmptyStateKind) -> CGFloat {
        let view = EmptyStateView(kind: kind, environment: environment())
        return NSHostingController(rootView: view).sizeThatFits(in: .zero).height
    }

    @Test("an account without repositories is explained in a height the smallest window has")
    func noRepositories() {
        #expect(smallestHeight(of: .noRepositories(account: idle)) <= roomInTheSmallestWindow)
    }

    @Test("an empty preset that names an idle account fits as well")
    func nothingMatchesWithAnIdleAccount() {
        let kind = EmptyStateKind.nothingMatches(presetName: "GitHub (prokopsimek) · Waiting for my review", idle: idle)
        #expect(smallestHeight(of: kind) <= roomInTheSmallestWindow)
    }

    @Test("the first screen of a new installation fits, sample data offer included")
    func noAccounts() {
        #expect(smallestHeight(of: .noAccounts) <= roomInTheSmallestWindow)
    }
}
