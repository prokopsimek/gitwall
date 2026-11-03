import AppKit

/// The Item menu. Every entry goes to the key window's ``ItemWindowController`` through the responder chain, so it
/// works in any window that shows Detail and is disabled elsewhere.
@MainActor
enum ItemMenu {
    static func build() -> NSMenu {
        let menu = NSMenu(title: "Item")
        let show = add(menu, "Show Detail", #selector(ItemWindowController.showItemDetail(_:)), " ", [])
        show.toolTip = "Space or Return"
        // A second key for the same command: hidden, but its key equivalent still works.
        let showWithReturn = add(menu, "Show Detail", #selector(ItemWindowController.showItemDetail(_:)), "\r", [])
        showWithReturn.isHidden = true
        showWithReturn.allowsKeyEquivalentWhenHidden = true
        add(menu, "Close Detail", #selector(ItemWindowController.closeItemDetail(_:)), "\u{1b}", [])
        add(menu, "Show Detail Panel", #selector(ItemWindowController.toggleItemDetail(_:)), "i", [.command, .option])
        menu.addItem(.separator())
        add(menu, "Open in Browser", #selector(ItemWindowController.openItemInBrowser(_:)), "\r", [.command])
        menu.addItem(.separator())
        add(menu, "Copy Link", #selector(ItemWindowController.copyItemLink(_:)), "c", [.command])
        add(menu, "Copy Reference", #selector(ItemWindowController.copyItemReference(_:)), "c", [.command, .shift])
        add(menu, "Copy Branch Name", #selector(ItemWindowController.copyItemBranch(_:)), "c", [.command, .option])
        add(menu, "Copy “gh pr checkout” Command", #selector(ItemWindowController.copyItemCheckoutCommand(_:)), "", [])
        return menu
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}
