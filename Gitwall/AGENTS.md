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
- `OAuthCoordinator` owns only the window-bound parts (device code display, `ASWebAuthenticationSession`).
  The protocol work is in GitwallAuth.
- `AppEnvironment.start` registers the app as a login item when `AppConfig.shouldRegisterAtLogin` says so, and
  records it in the settings. A sandboxed run (`--debug-fresh`, the test host) never touches login items,
  because `SMAppService.mainApp` would register the developer's own build.
- Sample data (`AppEnvironment.enterSampleData`) is the user-facing "demonstration mode" App Review asked for
  under guideline 2.1(a); `--debug-demo` stays a Debug-only screenshot mode with its own popover behaviour, so
  the two flags are separate. Sample data is offered only while `config.accounts` is empty, and every write path
  must check `usesSampleContent`, never `isDemo` alone, or fictional accounts reach the App Group.
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
| `--debug-onboarding-step <step>` | Opens the walkthrough at one step (`welcome`, `account`, `repositories`, `presets`, `notifications`, `startup`, `widget`), so a screen can be checked without clicking through. Pairs well with `--debug-demo`. |
