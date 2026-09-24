# Gitwall – conventions for agents

Native macOS app (Swift 6, SwiftUI, WidgetKit, min macOS 14). The menu bar agent fetches pull requests and
issues from GitHub and GitLab and writes a JSON snapshot into the App Group; desktop widgets only read that
snapshot. Product decisions and milestones live in `docs/PLAN.md`; do not re-decide them silently. Decisions
with lasting consequences are recorded in `docs/adr/`.

## Layout

- `project.yml` – XcodeGen spec, the only source of truth for targets, entitlements, Info.plist.
  Never edit `Gitwall.xcodeproj` (generated, git-ignored).
- `Gitwall/` – app target. See `Gitwall/AGENTS.md`.
- `GitwallWidget/` – widget extension. See `GitwallWidget/AGENTS.md`.
- `Packages/` – local SPM packages with all the logic. See `Packages/AGENTS.md`.
- `Scripts/` – release and asset tooling. See `Scripts/AGENTS.md`.
- `docs/` – public site (GitHub Pages), plan, release guide, App Store copy, ADRs.

## Rules

- Logic goes into packages and is developed test-first (Swift Testing, `swift test`). App and widget targets
  stay thin; anything with a branch in it belongs in a package.
- Providers must not leak provider-specific types into UI. Add capabilities to `ProviderCapabilities`
  instead of `if kind == .github` in views.
- The widget never touches the network or the Keychain.
- Tokens only in the Keychain. `config.json` in the App Group must never contain secrets.
- Incoming `gitwall://` URLs are handled in `NSApplicationDelegate.application(_:open:)`.
- Swift 6 language mode, strict concurrency. Stateful services are `actor`s or `@MainActor` observables;
  no `@unchecked Sendable` without a comment explaining why.
- User-facing strings go through the String Catalog (English only for now).
- Identifiers: bundle `cz.prokopsimek.gitwall`, App Group `ZHU9NYW7PP.cz.prokopsimek.gitwall`,
  URL scheme `gitwall`, team `ZHU9NYW7PP`.
- Never commit credentials. API keys live in `~/.appstoreconnect/private_keys/`; the GitLab and GitHub client
  IDs in `OAuthClients.swift` are public identifiers of public OAuth clients and belong in the repository.

## Commands

```sh
make generate        # xcodegen, only when project.yml changed; after adding or removing a file run
                     # `xcodegen generate --spec project.yml` or the new file is not compiled
make build           # Debug build into build/DerivedData
make run             # build + launch
make install         # Release build into ~/Applications (daily driver); override with
                     # `make install INSTALL_APP=/Applications/Gitwall.app` to keep the app there instead.
                     # Only one copy of Gitwall.app may stay installed — see GitwallWidget/AGENTS.md
make test-packages   # swift test for every package
make test            # packages + xcodebuild test
make archive         # Release archive for the App Store / notarization
make release         # Developer ID archive, notarize, staple, zip; prints the `gh release create` command (see docs/RELEASING.md)
```

Debug launch arguments (see `Gitwall/AGENTS.md`): `--debug-fresh`, `--debug-reset`, `--debug-github-token`,
`--debug-repos`, `--debug-demo`, `--debug-demo-preset`, `--debug-demo-widgets`, `--debug-onboarding-step`.

Unified log: `/usr/bin/log stream --predicate 'subsystem == "cz.prokopsimek.gitwall"' --info`
(note the full path; zsh has a `log` builtin).

## Communication

Talk to Prokop in Czech. Code, identifiers, comments and commit messages in English.
Commits follow Conventional Commits.

## Ship recipe
- Integrace: branch + PR, squash merge for code; `chore(release): version X, build N` bump commits go straight to `main`
- Release: manual from Prokop's Mac with the App Store Connect API key and the Developer ID certificate, following `docs/RELEASING.md`: bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml` → `chore(release)` commit → `make test` → `make archive` and the App Store export/upload → `make release` (notarized zip) → `gh release create vX.Y.Z` with the zip and `.sha256` → App Store submission; TODO(Prokop): who may submit a stable release
- Deploy: none (no server); `docs/` is the GitHub Pages site (legacy build from `main:/docs`), rebuilt on every push → https://prokopsimek.github.io/gitwall/
- Ověření: `gh release view vX.Y.Z --repo prokopsimek/gitwall` lists the zip and `.sha256`; `spctl -a -vv -t exec Gitwall.app` reports "Notarized Developer ID"; version and build = `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`; App Store state via `Scripts/asc.py`; smoke: `make test`, then `make run` and check the popover, one widget per size and a `gitwall://` link; migrations: none
- Board: none (no GitHub Project; status and milestones live in `docs/PLAN.md`)
