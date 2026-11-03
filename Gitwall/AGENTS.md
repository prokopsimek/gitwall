# App target

AppKit-driven: `@main` `AppDelegate` runs `NSApplication` directly, because a menu bar app cannot rely on the
SwiftUI `Settings` scene or on `onOpenURL`. Every window is an `NSWindowController` with a SwiftUI root view.

| Area | Files |
|---|---|
| Entry point, menu, deep links | `App/AppDelegate.swift`, `App/MainMenuController.swift` |
| Shared state | `App/AppEnvironment.swift` (`@MainActor @Observable`) |
| Menu bar | `StatusItem/` (left click popover, right click menu) |
| Main window | `MainWindow/` |
| Walls window | `Walls/` (window, tiles, Wall menu, keys, rotation, configuration copy and paste) |
| Settings | `Settings/` (tabs: Accounts, Repositories, Presets, General, About) |
| First run | `Onboarding/` |
| Services | `Services/` (avatars, notifications, OAuth coordinator) |
| Shared views | `Shared/` (item rows and empty states used by popover and window) |
| Detail | `Detail/` (`DetailModel` per window, `ItemDetailService` app-wide, `ItemWindowController` and the Item menu) |

## Rules

- No branching logic here that a package could own. `AppEnvironment` orchestrates; it does not compute.
- Accounts enter and leave through `AppConfig.adding(_:pullRequestTerm:)` and `AppConfig.removing(accountID:)`
  (GitwallCore), which own the per-account default presets and their cleanup. Do not append to
  `config.accounts` directly.
- `AppEnvironment.addAccount` and `replaceCredential` take a `StoredToken`, so refresh tokens and expiry
  dates survive. The sync engine reads through `RefreshingTokenReader`, which refreshes OAuth tokens
  silently; the user signs in once.
- Repositories, presets and widgets hang on the account record. Changing how an account signs in goes through
  `replaceCredential`, never through remove and add; Add Account asks first when the owner of a credential is
  already connected (`AppEnvironment.connectedAccount`, which matches by provider, server and login). See
  [ADR 0011](../docs/adr/0011-switching-sign-in-keeps-the-account.md).
- An account without sources fetches nothing and still syncs as `ok`. Every place that can be empty because of it
  names the account and links to Settings › Repositories for it: `AppEnvironment.listState(for:)` through
  `AppConfig.emptiness(of:)`, the Accounts row, and the preset editor through `AppConfig.idleAccounts(visibleTo:)`.
- A text with `.fixedSize(horizontal: false, vertical: true)` needs a minimum width from an ancestor. A window
  asks for its smallest size by offering no room; the text answers with one letter per line, and the
  `NavigationSplitView` of the main window lays itself out that tall, so the sidebar and the header leave the
  window (`GitwallTests/EmptyStateLayoutTests`).
- Two `ForEach` over the same models in one `Form` section give two rows one identity, and the second draws the
  first one's row. Put the second inside a container of its own, as the preset editor does for idle accounts.
- The preset editor works on its own copy of the preset (`@State`). Whatever changes a preset from outside the editor
  while it is on screen must give the editor a new identity, or the editor keeps the old values and its next edit
  writes them back. Every paste (⇧⌘V, the empty Walls window, Settings) goes through
  `AppEnvironment.pasteConfiguration`, which bumps `pasteCount`; the editor takes it into its `.id`. Copy and paste
  only move text between the pasteboard and `GitwallFile`/`PresetTransfer` (GitwallCore, `docs/adr/0013`, `0014`).
- `AppEnvironment.items(for:)` answers from `FilterCache` (GitwallCore): one answer per saved preset, for the minute,
  emptied when the snapshot or anything but the walls changes. A preset that differs from the saved one, as the
  editor's copy does, is filtered every time. A write that changes only walls reloads no widget.
- `OAuthCoordinator` owns only the window-bound parts (device code display, `ASWebAuthenticationSession`).
  The protocol work is in GitwallAuth.
- `AppEnvironment.start` registers the app as a login item when `AppConfig.shouldRegisterAtLogin` says so, and
  records it in the settings. A sandboxed run (`--debug-fresh`, the test host) never touches login items,
  because `SMAppService.mainApp` would register the developer's own build.
- Sample data (`AppEnvironment.enterSampleData`) is the user-facing "demonstration mode" App Review asked for
  under guideline 2.1(a); `--debug-demo` stays a Debug-only screenshot mode with its own popover behaviour, so
  the two flags are separate. Sample data is offered only while `config.accounts` is empty, and every write path
  must check `usesSampleContent`, never `isDemo` alone, or fictional accounts reach the App Group.
- **Every screen that is empty for lack of an account offers sample data** through `SampleDataOffer`
  (`Shared/SampleDataOffer.swift`): the walkthrough, Settings › Accounts, the Add Account sheet, the empty
  popover and main window, and the Help menu. The second rejection (2026-09-17) came from a Mac where the
  walkthrough had already been finished, and it was the only way in. See
  [ADR 0010](../docs/adr/0010-sample-data-is-reachable-without-the-walkthrough.md).
- Sample data behaves like a working installation: Refresh brings in another review request and routes
  notifications, Settings › Repositories lists `DemoData.discovery`, and items explain themselves instead of
  opening a fictional URL. A real account added while it is on ends it first, so nothing is left in memory only.
- The Walls window takes its keys (Tab, arrows, Return, Space, 1–4, Delete, Escape) in its own event monitor
  (`WallsWindowController.handleKey`): AppKit does not deliver plain printable keys as menu shortcuts, and SwiftUI would
  spend Tab on focus. Which key means what (`WallsKeys`) and when a command is enabled (`WallsCommand.isEnabled`) are
  GitwallCore's; a key only acts when its command is enabled, and a disabled one leaves the key to the window. A key without ⌘, ⌥ or ⌃ acts only while the Walls
  window is the key window and no name is typed, so the popover or a sheet in front keeps its arrows and Return.
- The Walls window is an `ItemWindowController` with Detail as its inspector. `WallsModel` owns the window's
  `DetailModel` and drives it from its selection (`syncDetail`): Detail follows ↑↓, its list is the selected tile's
  rows, and "Why it's here" uses that tile's preset (`detailPreset`). A click on an item goes through
  `WallsModel.activate`, which shows Detail; Return, Space and Escape are `WallsCommand.showDetail` and `.closeDetail`
  sent as the Item menu's actions (Escape finishes editing first), and ⌘↩ and a double click open the browser. Item
  actions live only in the Item menu; the Wall menu keeps wall and tile actions.
- Wall edits go through `WallsModel.apply`, which registers the inverse `WallChange` with the window's own undo manager.
  Undo finds a wall by its id, so a paste that only adds walls leaves the history alone. A paste that replaces a wall
  clears it (`AppEnvironment.onWallsReplacedByPaste`): undoing an earlier edit would write the old wall over the pasted
  one.
- Full screen the grid fills the screen beside Detail (`WallLayout.fit`). `WallsWindowController` sets
  `WallsModel.isFullScreen` as the window enters and leaves full screen; ⌘+ and ⌘− then change `fullScreenZoom`, which
  is relative to the fit, and the window's own `zoom` stays as it was.
- The name typed into a tab lives in `WallsModel.renameDraft`. Switching walls commits it first, so ⌘⇧] or a click on
  another tab in the middle of a rename keeps the name.
- Activation policy: the app is `regular` in Info.plist and drops to `accessory` when the user hides the
  Dock icon. Going the other way at runtime leaves a generic Dock icon, hence the order in
  `applicationWillFinishLaunching`.

- **Detail in a window**: subclass `ItemWindowController` (it is the window's delegate and answers the Item menu
  through the responder chain), attach `.itemDetailInspector(model, environment:, preset:)` to the list and call
  `model.show(item.id)` on a click. A click in such a list selects and shows Detail, a double click and ⌘↩ open the
  browser; the popover and the widget still open the browser. Space, ↩ and Esc stay typing keys while a text field
  is edited (`validateMenuItem`); ⌘C is Edit › Copy, never an Item menu key. Esc never reaches the
  Item menu's Close Detail as a key equivalent, so `itemDetailInspector` closes Detail with `.onExitCommand`; ⌘F gives
  the search field the keyboard through AppKit (`MainWindowController.focusSearch`), which `@FocusState` from a menu
  command did not. `DetailModel` marks an item seen only
  after its detail loaded while it is still shown (`ItemDetailService.markSeen`, `persist: !usesSampleContent`;
  sample items keep their times in memory), opens only http(s) links, and clears a selection the new preset does
  not list (`presetDidChange`). Replacing a credential or removing an account calls `details.forget(accountID:)`.
  See `docs/adr/0015`.

## Debug launch arguments (Debug builds only)

| Argument | Effect |
|---|---|
| `--debug-fresh` | Throwaway container and in-memory Keychain. Use this for anything destructive. The app test host gets the same automatically, so `make test-app` never touches your real configuration. |
| `--debug-reset` | Wipes accounts, tokens and snapshot. Refuses to run without `--debug-fresh`. |
| `--debug-github-token <pat> [--debug-repos a/b,c/d]` | Creates a GitHub account without clicking. |
| `--debug-demo [--debug-demo-preset <n>] [--debug-demo-widgets]` | Fictional data from `GitwallCore.DemoData` for App Store screenshots; widgets appear as borderless windows. |
| `--debug-demo --debug-demo-idle-account <n>` | The sample account at that index as if it had just been removed and added again: no repositories, no items, its three presets at the end of the list (`--debug-demo-preset 7` shows the first of them). For the hints that send the user to Settings › Repositories. |
| `--debug-detail <owner/repo#123>` | Selects that item in the main window and opens Detail, for screenshots. |
| `--debug-detail-expand <folds>` | Opens Detail's folded sections (`description`, `conversation`, `files`, `linked`, `metadata`, comma separated) and scrolls to the first. |
| `--debug-demo --debug-demo-walls [window\|edit\|empty\|fullscreen]` | Only the Walls window at 1280×800 with the sample walls: as it opens (first item selected), in edit mode, with no walls, or full screen. |
| `--debug-onboarding-step <step>` | Opens the walkthrough at one step (`welcome`, `account`, `repositories`, `presets`, `notifications`, `startup`, `widget`), so a screen can be checked without clicking through. Pairs well with `--debug-demo`. |
