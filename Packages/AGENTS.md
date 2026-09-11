# Packages

All logic lives here, test-first with Swift Testing. `swift test --package-path Packages/<name>`, or
`make test-packages` for all of them. Dependencies point one way only:

```
GitwallCore ◀── GitwallUI, GitwallAuth, GitwallGitHub, GitwallGitLab
```

| Package | Owns |
|---|---|
| `GitwallCore` | Models (`WorkItem`, `Account`, `Preset`, `Snapshot`), `GitProvider` protocol, `FilterEngine`, `SyncEngine`, snapshot/config stores, `SnapshotDiff`, `DeepLink`, `OnboardingStep`, `DemoData`. |
| `GitwallUI` | Row views, status icons, time formatting shared by popover, window and widget. |
| `GitwallAuth` | Keychain `TokenStore`, `StoredToken`, OAuth flows (`GitHubDeviceFlow`, `GitLabPKCEFlow`), `PKCE`, `TokenRefresher`, `RefreshingTokenReader`, token expiry parsing, `OAuthClients` (public client IDs). |
| `GitwallGitHub` | `GitHubProvider`: GraphQL for lists, REST for identity and discovery, Link pagination. |
| `GitwallGitLab` | `GitLabProvider`: one GraphQL request per project or group (complexity limit), REST discovery. Sends the token as a bearer credential, which covers both personal access tokens and OAuth. |

## Rules

- Mock only at the HTTP boundary: each provider package has an `HTTPTransport`, GitwallAuth an
  `OAuthTransport`. Never mock our own types.
- Provider responses are mapped from real fixtures under `Tests/.../Fixtures`, captured from live APIs.
- Integration tests that need a real server or a human are gated behind an environment variable and skipped
  by default (`GITWALL_GITHUB_TOKEN` + optional `GITWALL_GITHUB_REPO`, `GITWALL_GITLAB_TOKEN` + `GITWALL_GITLAB_URL`,
  `GITWALL_OAUTH_INTERACTIVE`).
- A query change must keep working with fine-grained tokens. When you add a REST endpoint or a GraphQL type,
  check it against the provider's fine-grained permission list and update the token guide in the README.
- Nothing here may import AppKit or SwiftUI except GitwallUI.
- `ItemFilter` decodes every key with `decodeIfPresent`: a `config.json` written by an older build must keep
  loading, so a new field needs a default, never a migration.
- Filter categories combine with AND, values inside one category with OR. Two deliberate exceptions live in
  `FilterEngine`: a draft that names me as a reviewer passes a review preset even when drafts are off (cloud
  agents cannot mark their pull requests ready), and author logins are compared without a trailing `[bot]`,
  because GitHub GraphQL returns `renovate` where REST returns `renovate[bot]`.
