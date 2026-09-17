import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item: left click toggles the popover, right click shows the actions menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var menu = makeMenu()

    init(environment: AppEnvironment) {
        self.environment = environment
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Gitwall")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityIdentifier("gitwall-status-item")
        }

        // Demo mode pins the popover so the screenshot script can capture it next to the other windows,
        // and forces the light appearance because a window-only capture flattens the dark material to grey.
        popover.behavior = environment.isDemo ? .applicationDefined : .transient
        if environment.isDemo { popover.appearance = NSAppearance(named: .aqua) }
        popover.animates = false
        popover.delegate = self
        // The hosting controller reports no size before the first `show`, so the popover would be placed for its
        // 320×320 default and then grow upwards over the menu bar once SwiftUI lays out the real content.
        popover.contentSize = PopoverView.size
        popover.contentViewController = NSHostingController(rootView: PopoverView(environment: environment))

        environment.onShowPopover = { [weak self] in self?.showPopover() }
        observeBadge()
    }

    // MARK: - Actions

    @objc private func handleClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if environment.isDemo { addDemoBackdrop() }
    }

    /// Demo mode: an opaque content background. A window-only capture renders the popover's translucent
    /// material as dark grey whatever sits behind it, which makes the screenshot unreadable.
    private func addDemoBackdrop() {
        guard let view = popover.contentViewController?.view else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func showMenu() {
        popover.performClose(nil)
        refreshMenuState()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Badge

    private func observeBadge() {
        withObservationTracking {
            statusItem.button?.title = environment.menuBarBadge.isEmpty ? "" : " \(environment.menuBarBadge)"
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeBadge() }
        }
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Gitwall Window", action: #selector(openPopover), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.tag = MenuTag.launchAtLogin.rawValue
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Gitwall", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Gitwall", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    private enum MenuTag: Int {
        case launchAtLogin = 1
    }

    private func refreshMenuState() {
        menu.item(withTag: MenuTag.launchAtLogin.rawValue)?.state = environment.launchesAtLogin ? .on : .off
    }

    @objc private func openPopover() {
        environment.openMainWindow()
    }

    @objc private func refresh() {
        Task { await environment.refresh() }
    }

    @objc private func openSettings() {
        environment.openSettings(environment.needsOnboarding ? .accounts : .presets)
    }

    @objc private func toggleLaunchAtLogin() {
        environment.launchesAtLogin.toggle()
    }

    @objc private func showAbout() {
        environment.openSettings(.about)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
