# App target

AppKit-driven: `@main` `AppDelegate` runs `NSApplication` directly, because a menu bar app cannot rely on the
SwiftUI `Settings` scene or on `onOpenURL`. Every window is an `NSWindowController` with a SwiftUI root view.

| Area | Files |
|---|---|
| Entry point, menu, deep links | `App/AppDelegate.swift`, `App/MainMenuController.swift` |
| Shared state | `App/AppEnvironment.swift` (`@MainActor @Observable`) |
| Menu bar | `StatusItem/` (left click popover, right click menu) |
| Main window | `MainWindow/` |
| Settings | `Settings/` (tabs: Accounts, Repositories, Presets, General, About) |
| First run | `Onboarding/` |
| Services | `Services/` (avatars, notifications, OAuth coordinator) |
| Shared views | `Shared/` (item rows and empty states used by popover and window) |

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
- Activation policy: the app is `regular` in Info.plist and drops to `accessory` when the user hides the
  Dock icon. Going the other way at runtime leaves a generic Dock icon, hence the order in
  `applicationWillFinishLaunching`.

## Debug launch arguments (Debug builds only)

| Argument | Effect |
|---|---|
| `--debug-fresh` | Throwaway container and in-memory Keychain. Use this for anything destructive. The app test host gets the same automatically, so `make test-app` never touches your real configuration. |
| `--debug-reset` | Wipes accounts, tokens and snapshot. Refuses to run without `--debug-fresh`. |
| `--debug-github-token <pat> [--debug-repos a/b,c/d]` | Creates a GitHub account without clicking. |
| `--debug-demo [--debug-demo-preset <n>] [--debug-demo-widgets]` | Fictional data from `GitwallCore.DemoData` for App Store screenshots; widgets appear as borderless windows. |
| `--debug-demo --debug-demo-idle-account <n>` | The sample account at that index as if it had just been removed and added again: no repositories, no items, its three presets at the end of the list (`--debug-demo-preset 7` shows the first of them). For the hints that send the user to Settings › Repositories. |
| `--debug-onboarding-step <step>` | Opens the walkthrough at one step (`welcome`, `account`, `repositories`, `presets`, `notifications`, `startup`, `widget`), so a screen can be checked without clicking through. Pairs well with `--debug-demo`. |
