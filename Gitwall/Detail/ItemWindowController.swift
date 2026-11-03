import AppKit
import GitwallCore
import GitwallUI

/// A window that lists items and shows Detail. It answers the Item menu for its ``DetailModel`` through the responder
/// chain (it is its window's delegate, which AppKit asks after the views), so the menu works in whichever such window
/// is key. The main window is one; another window becomes one by subclassing this and attaching
/// `itemDetailInspector` to its list.
@MainActor
class ItemWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let environment: AppEnvironment
    let detail: DetailModel

    init(window: NSWindow, environment: AppEnvironment, detail: DetailModel) {
        self.environment = environment
        self.detail = detail
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var item: WorkItem? { detail.selectedItem }

    private var account: Account? { item.flatMap { environment.config.account(id: $0.accountID) } }

    /// Space, ↩ and Esc are typing keys in a text field; the menu leaves them alone while one is being edited.
    private var isEditingText: Bool { window?.firstResponder is NSText }

    // MARK: Item menu

    @objc func showItemDetail(_ sender: Any?) { detail.present() }

    @objc func closeItemDetail(_ sender: Any?) { detail.close() }

    @objc func toggleItemDetail(_ sender: Any?) { detail.toggle() }

    @objc func openItemInBrowser(_ sender: Any?) {
        guard let item else { return }
        environment.open(item)
    }

    @objc func copyItemLink(_ sender: Any?) {
        guard let item else { return }
        copy(item.url.absoluteString)
    }

    /// Edit › Copy (⌘C) when no text has the focus: the link, as Item › Copy Link says. In a text field the field
    /// editor answers `copy:` first and copies the selected text; Copy Link itself has no key, so ⌘C stays Edit's.
    @objc(copy:) func copyFromEditMenu(_ sender: Any?) { copyItemLink(sender) }

    @objc func copyItemReference(_ sender: Any?) {
        guard let item else { return }
        copy(DetailPresentation.reference(of: item))
    }

    @objc func copyItemBranch(_ sender: Any?) {
        guard let branch = branchName else { return }
        copy(branch)
    }

    @objc func copyItemCheckoutCommand(_ sender: Any?) {
        guard let item else { return }
        copy(DetailPresentation.checkoutCommand(of: item, baseURL: account?.baseURL))
    }

    private var branchName: String? {
        guard case .loaded(let detail)? = detail.selectedRemote, let branches = try? detail.branches.get() else { return nil }
        return branches.head
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showItemDetail(_:)):
            return !isEditingText && (item != nil || !detail.visibleItemIDs.isEmpty)
        case #selector(closeItemDetail(_:)):
            return !isEditingText && detail.isPresented
        case #selector(toggleItemDetail(_:)):
            menuItem.title = detail.isPresented ? "Hide Detail Panel" : "Show Detail Panel"
            return true
        case #selector(openItemInBrowser(_:)):
            let host = account.flatMap(environment.provider(for:))?.capabilities.hostName
            menuItem.title = host.map { "Open on \($0)" } ?? "Open in Browser"
            return item != nil
        case #selector(copyFromEditMenu(_:)):
            return !isEditingText && item != nil
        case #selector(copyItemLink(_:)), #selector(copyItemReference(_:)):
            return item != nil
        case #selector(copyItemBranch(_:)):
            return item?.kind == .pullRequest && branchName != nil
        case #selector(copyItemCheckoutCommand(_:)):
            return item?.kind == .pullRequest && account?.kind == .github
        default:
            return true
        }
    }
}
