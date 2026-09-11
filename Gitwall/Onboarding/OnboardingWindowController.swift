import AppKit
import GitwallCore
import SwiftUI

/// Owns the first-run walkthrough window. A separate window, not a sheet, so the user can move it around
/// while they create a token or approve a sign-in in the browser.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let environment: AppEnvironment
    private let onFinish: () -> Void

    init(environment: AppEnvironment, onFinish: @escaping () -> Void) {
        self.environment = environment
        self.onFinish = onFinish
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Welcome to Gitwall"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(environment: environment, finish: { [weak self] in self?.finish() })
        )
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing the window counts as finishing: the walkthrough never traps anyone, and Settings has everything.
    func windowWillClose(_ notification: Notification) {
        markCompleted()
    }

    private func finish() {
        markCompleted()
        window?.close()
        onFinish()
    }

    private func markCompleted() {
        guard !environment.config.settings.onboardingCompleted else { return }
        var settings = environment.config.settings
        settings.onboardingCompleted = true
        environment.updateSettings(settings)
    }
}
