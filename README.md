# Gitwall

Pull requests and issues from all your repositories, on your Mac desktop.

Gitwall is a free, open-source macOS menu bar app with desktop widgets. It aggregates
open pull requests (merge requests) and issues across GitHub and GitLab, including
self-hosted instances, and shows them sorted by latest activity with review, CI,
draft and merge-conflict state. Click an item to open it in your browser.

- Multiple widgets, each with its own size and preset (which repositories, PRs and/or
  issues, filters).
- Unified filters across providers: author, review requested, assignee, labels,
  review state, CI state, drafts, age, milestone, text.
- Notifications per preset (new item, review requested, approved, changes requested,
  CI failed, merged, closed).
- Sign in once with GitHub or GitLab, or use a personal access token. Credentials live in the macOS
  Keychain and OAuth tokens are refreshed silently, so you are never asked to sign in again.
- No backend. The app talks to GitHub / GitLab APIs directly from your Mac.

Requires macOS 14 Sonoma or later.

## Status

Beta. GitHub (github.com and GitHub Enterprise Server) and GitLab (gitlab.com and self-managed,
GitLab 16 or newer) work end to end: sign in with GitHub or GitLab or paste a personal access token,
repository, organization and group discovery, presets with filters, menu bar popover, configurable desktop
widgets in four sizes, notifications, first-run walkthrough. Version 0.2.0 is on GitHub Releases; the App Store
version is in review. The roadmap is in `docs/PLAN.md`.

## Install

Download the notarized build from [GitHub Releases](https://github.com/prokopsimek/gitwall/releases/latest),
unzip it and move Gitwall.app to Applications. The Mac App Store version is in review.

## Widgets

1. Right-click the desktop and choose **Edit Widgets…** (or click the clock in the menu bar and scroll to
   **Edit Widgets**).
2. Search for **Git** and drag a widget to the desktop: **Counter** (small), **List** (medium),
   **Board** (large) or **Wide Board** (extra large).
3. Right-click the widget → **Edit “Gitwall”** → choose the preset it should show.

Add as many widgets as you like; each keeps its own preset and size. Presets (which accounts,
repositories, item kinds and filters) are managed in the app under Settings › Presets.

## Building from source

Prerequisites: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make generate   # creates Gitwall.xcodeproj from project.yml
make build      # builds the app into build/DerivedData
make run        # builds and launches it
make test       # swift test for packages + xcodebuild test
```

`project.yml` is the source of truth; the generated `Gitwall.xcodeproj` is not committed.
Logic lives in local Swift packages under `Packages/`; the app and widget targets are thin shells.

## License

MIT. See [LICENSE](LICENSE).
