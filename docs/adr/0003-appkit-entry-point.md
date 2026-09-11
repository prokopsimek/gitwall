# 3. AppKit entry point instead of the SwiftUI App lifecycle

Date: 2026-09-10

## Context

The first version used `@main struct GitwallApp: App` with a `Settings` scene. Two problems followed: the
`Settings` scene and the settings window opened from the menu bar were different windows, so ⌘, and the menu
item disagreed; and `onOpenURL` on a SwiftUI view is not reliable for an app whose windows may all be closed,
which is the normal state of a menu bar app.

## Decision

`@main final class AppDelegate` with `static func main()` running `NSApplication.shared.run()`. The main menu
is built programmatically in `MainMenuController`. Every window (main, settings, onboarding) is an
`NSWindowController` hosting a SwiftUI root view. `gitwall://` URLs arrive in `application(_:open:)`.

## Consequences

- One settings window, one main window, predictable ⌘, ⌘W ⌘R ⌘Q.
- Deep links from widgets and notifications work even when no window exists.
- Windows are created explicitly, which is more code than a SwiftUI scene but makes the Dock click, the menu
  bar item and the deep links share one path.
