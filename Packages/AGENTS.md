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
- `ItemFilter` and `AppSettings` decode every key with `decodeIfPresent`: a `config.json` written by an older
  build must keep loading, so a new field needs a default, never a migration.
- Whether a fresh installation switches Launch at login on for itself is `AppConfig.shouldRegisterAtLogin`; the
  app only carries it out. It fires once, and never on an installation that predates
  `AppSettings.launchAtLoginConfigured`, because what such an installation has now is the user's choice.
- Archived repositories are dropped by the provider, never by `FilterEngine` (see `docs/adr/0007`). GitHub asks
  for `isArchived` in the repository queries and the search query carries `archived:false`; GitLab selects
  `archived` on the project root and must never pass `includeArchived` to a group connection, because GitLab
  already leaves archived projects out by default.
- A GitHub review request addressed to a team resolves to the token owner when they are in that team. The
  membership query (`GraphQLQueries.viewerTeams`, classic tokens need `read:org`) runs at most once per
  `fetchItems`, and only for a batch that actually contains a team request; a refusal is logged and leaves the
  queue as it was.
- Filter categories combine with AND, values inside one category with OR. Two deliberate exceptions live in
  `FilterEngine`: a draft that names me as a reviewer passes a review preset even when drafts are off (cloud
  agents cannot mark their pull requests ready), and author logins are compared without a trailing `[bot]`,
  because GitHub GraphQL returns `renovate` where REST returns `renovate[bot]` (`LoginMatch`).
- `ItemFilter.query` is GitHub search syntax read by `SearchQuery` and evaluated **locally**, over the snapshot,
  for both providers; it is never sent to a server. A space or `AND` is AND, `OR` is OR and parentheses nest at
  most five levels, as GitHub documents; AND binds tighter, as in GitHub's parser. Commas inside a term are OR and
  a leading `-` excludes that term. There is no `NOT` and no `-(…)`, and a bare word, `@login` included, is text (see `docs/adr/0008` and
  `docs/adr/0009`). Only qualifiers `WorkItem` can answer are accepted; anything else is a parse error, and an
  unreadable query matches nothing so a typo cannot widen a preset. Adding a qualifier means adding it to
  `SearchQuery.Qualifier`, to `SearchQueryTests` and to the table in the README.
