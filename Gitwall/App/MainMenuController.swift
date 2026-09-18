import AppKit

/// Programmatic main menu. The app has no storyboard and no SwiftUI `App` scene, so the standard
/// menus (and their keyboard shortcuts, including Edit for text fields) are built here.
@MainActor
final class MainMenuController: NSObject {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
        NSApp.mainMenu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Gitwall", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Gitwall", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Gitwall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Gitwall"))

        // Edit menu: needed so text fields get ⌘X/⌘C/⌘V/⌘A.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        // View menu
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
        let sidebar = view.addItem(withTitle: "Toggle Sidebar", action: NSSelectorFromString("toggleSidebar:"), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view, title: "View"))

        // Window menu
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Gitwall", action: #selector(openMainWindow), keyEquivalent: "1").target = self
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        // Help menu
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Gitwall Help", action: #selector(openWebsite), keyEquivalent: "?").target = self
        help.addItem(withTitle: "Add Widget to Desktop…", action: #selector(showWidgetHelp), keyEquivalent: "").target = self
        help.addItem(withTitle: "Look Around with Sample Data", action: #selector(showSampleData), keyEquivalent: "").target = self
        help.addItem(.separator())
        help.addItem(withTitle: "Privacy Policy", action: #selector(openPrivacy), keyEquivalent: "").target = self
        help.addItem(withTitle: "Report an Issue", action: #selector(openIssues), keyEquivalent: "").target = self
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: Actions

    @objc private func showAbout() { environment.openSettings(.about) }
    @objc private func openSettings() { environment.openSettings(environment.needsOnboarding ? .accounts : .presets) }
    @objc private func refresh() { Task { await environment.refresh() } }
    @objc private func openMainWindow() { environment.openMainWindow() }
    @objc private func showWidgetHelp() { environment.showWidgetHelp() }
    @objc private func showSampleData() {
        environment.enterSampleData()
        environment.openMainWindow()
    }
    @objc private func openWebsite() { open(Links.website) }
    @objc private func openPrivacy() { open(Links.privacy) }
    @objc private func openIssues() { open(Links.issues) }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

extension MainMenuController: NSMenuItemValidation {
    /// Sample data is only on offer while no account is connected (`AppEnvironment.canShowSampleData`).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(showSampleData) ? environment.canShowSampleData : true
    }
}

enum Links {
    static let website = "https://prokopsimek.github.io/gitwall/"
    static let privacy = "https://prokopsimek.github.io/gitwall/privacy/"
    static let source = "https://github.com/prokopsimek/gitwall"
    static let issues = "https://github.com/prokopsimek/gitwall/issues"
    static let tokenGuide = "https://github.com/prokopsimek/gitwall#personal-access-tokens"
}
