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
- Sign in once. Tokens live in the macOS Keychain and are refreshed silently.
- No backend. The app talks to GitHub / GitLab APIs directly from your Mac.

Requires macOS 14 Sonoma or later.

## Status

Beta. GitHub (github.com and GitHub Enterprise Server) with personal access tokens works
end to end: accounts, repository and organization discovery, presets with filters, menu bar
popover, configurable desktop widgets in four sizes, notifications. GitLab, OAuth sign-in
and App Store release are the next milestones (see `docs/PLAN.md`).

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
