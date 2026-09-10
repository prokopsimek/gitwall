# Gitwall – conventions for agents

Native macOS app (Swift 6, SwiftUI, WidgetKit, min macOS 14). Menu bar agent fetches
PRs/issues from GitHub and GitLab and writes a JSON snapshot into the App Group;
desktop widgets only read that snapshot. Product decisions and milestones live in
`docs/PLAN.md`; do not re-decide them silently.

## Layout

- `project.yml` – XcodeGen spec, the only source of truth for targets, entitlements,
  Info.plist. Never edit `Gitwall.xcodeproj` (it is generated and git-ignored).
- `Gitwall/` – app target: AppDelegate, status item, popover, settings, onboarding, URL handling.
- `GitwallWidget/` – widget extension: configuration intent, timeline provider, views.
- `Packages/GitwallCore` – models, `GitProvider` protocol, filters, snapshot/config stores, diff, deep links.
- `Packages/GitwallGitHub`, `Packages/GitwallGitLab` – providers; depend only on GitwallCore.
- `Packages/GitwallAuth` – Keychain token store, OAuth flows, token refresh.
- `Packages/GitwallUI` – row views and status icons shared by popover and widget.

## Rules

- Logic goes into packages and is developed test-first (Swift Testing, `swift test`).
  App and widget targets stay thin; anything with a branch in it belongs in a package.
- Providers must not leak provider-specific types into UI. Add capabilities to
  `ProviderCapabilities` instead of `if kind == .github` in views.
- The widget never touches the network or the Keychain.
- Tokens only in Keychain. `config.json` in the App Group must never contain secrets.
- Incoming `gitwall://` URLs are handled in `NSApplicationDelegate.application(_:open:)`.
- Swift 6 language mode, strict concurrency. Stateful services are `actor`s or
  `@MainActor` observables; no `@unchecked Sendable` without a comment explaining why.
- User-facing strings go through the String Catalog (English only for now).
- Identifiers: bundle `cz.prokopsimek.gitwall`, App Group `ZHU9NYW7PP.cz.prokopsimek.gitwall`,
  URL scheme `gitwall`, team `ZHU9NYW7PP`.

## Commands

```sh
make generate        # xcodegen
make build           # Debug build into build/DerivedData
make run             # build + launch
make test-packages   # swift test for every package
make test            # packages + xcodebuild test
```

Debug builds accept `--debug-reset`, `--debug-github-token <pat>` and `--debug-repos a/b,c/d`
launch arguments (see AppDelegate) so an end-to-end run needs no clicking:
`open build/DerivedData/Build/Products/Debug/Gitwall.app --args --debug-reset --debug-github-token "$(gh auth token)" --debug-repos owner/repo`.
Unified log: `/usr/bin/log stream --predicate 'subsystem == "cz.prokopsimek.gitwall"' --info` (note the full path; zsh has a `log` builtin).

Communicate with Prokop in Czech; code, commits and identifiers in English.
Commits follow Conventional Commits.
