# Packages

All logic lives here, test-first with Swift Testing. `swift test --package-path Packages/<name>`, or
`make test-packages` for all of them. Dependencies point one way only:

```
GitwallCore ◀── GitwallUI, GitwallAuth, GitwallGitHub, GitwallGitLab
```

| Package | Owns |
|---|---|
| `GitwallCore` | Models (`WorkItem`, `Account`, `Preset`, `Snapshot`), `GitProvider` protocol, `FilterEngine`, `SyncEngine`, snapshot/config stores, `SnapshotDiff`, `DeepLink`, `OnboardingStep`, `DemoData`, `PresetTransfer` (preset JSON for copy and paste), `Wall`/`Tile`/`TileSize`, `WallLayout` (with the full-screen `fit`), `GitwallFile` (presets and walls as one JSON file), `SyncStatus`, `FilterCache`, `WallsCommand`/`WallsKeys` (what the Walls window's menus and keys do, and when). |
| `GitwallUI` | Row views, status icons, time formatting shared by popover, window and widget; `TileView`, the tile drawn by both the widgets and the Walls window. |
| `GitwallAuth` | Keychain `TokenStore`, `StoredToken`, OAuth flows (`GitHubDeviceFlow`, `GitLabPKCEFlow`), `PKCE`, `TokenRefresher`, `RefreshingTokenReader`, token expiry parsing, `OAuthClients` (public client IDs). |
| `GitwallGitHub` | `GitHubProvider`: GraphQL for lists, REST for identity and discovery, Link pagination. |
| `GitwallGitLab` | `GitLabProvider`: one GraphQL request per project or group (complexity limit), REST discovery. Sends the token as a bearer credential, which covers both personal access tokens and OAuth. |
| `GitwallCore` · Detail | `ItemDetail`, `DetailFetcher` (on-demand fetch, shared while in flight), `DetailCache` (the one cache, kept by the app), `NextStep`, `LatestWord`, `WhatsNew`, `SeenStore` (`seen.json`), `FilterEngine.explain` (`MatchReason`), `DetailVisibility` (navigation that leaves nothing selected closes Detail). |
| `GitwallUI` · Detail | `DetailView` and its wording (`DetailPresentation`), `MarkdownView` and the native Markdown parser (`MarkdownBlock`). |
| `GitwallGitHub` · Detail | Item detail in two read-only GraphQL queries (`GraphQL+ItemDetail.swift`, `GitHubProvider+ItemDetail.swift`). |
| `GitwallCore` · Preset search | `PresetResult` (the last search per preset and account, with `PresetQueryFailure`), `Snapshot.presetResults` and `Snapshot.searchedAccounts`, `Preset.selectionFingerprint`, `PresetOutcome` and `PresetResult.merged`, `SyncSelection` (the presets a regular sync fetches), `PresetFreshness` and `PresetCountDisplay` (what a preset shows, its count, fetch on open), `SearchFindings` (what the diff learns from the searches), `ProviderCapabilities.presetSearch` with `GitProvider.capabilities(for:)`, `PresetSearch`/`PresetFetch` for `fetchPresetItems`, `ItemState` for `fetchItemStates`, `SyncEngine.syncPresets`. See `docs/adr/0017`. |
| `GitwallUI` · Preset search | `PresetCountPresentation`: the words for a preset's count ("12", "1000+", "–", "Query failed") and the placeholder of a list with nothing fetched yet. |
| `GitwallGitHub` · Preset search | `PresetSearchQuery` (a preset as an `ISSUE_ADVANCED` query, at least as wide as the local filter), the preset search with splitting and paging to 1000 (`GitHubProvider+PresetSearch.swift`), the item-state lookup over `nodes(ids:)` in batches of 100 (`GitHubProvider+ItemStates.swift`). |

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
  `fetchItems`, `fetchPresetItems` or `fetchItemStates`, and only for a batch that actually contains a team request.
  `GitHubProvider` also keeps a clean answer (`TeamSlugCache`, per account and token, five minutes), so preset
  searches and item-state lookups of one sync share a single query per account. A refusal or an answer with errors
  is not kept, so the next call asks again; it is logged by the number and types of the errors or the type of the
  thrown error, never GitHub's text, which can name an organization.
- Priority (`WorkItem.priority`) is the GitHub Projects field `Priority` (`projectPriority`), else the most urgent
  `p0`–`p3` label. The project value comes from `GitProvider.projectPriorities`, a separate request after
  `fetchItems` that never throws and never fails the sync: a refused scope is `.missingPermission`
  (`FetchStatus.projectAccess = .denied`, a hint in Settings), anything else `.failed`, which keeps the previous
  values. Never put `projectItems` into the list queries: a token without `read:project` would lose the whole list
  (see `docs/adr/0012`).
- The request count in `SyncReport` is every request the accounts send, counted by `RequestTally` (GitwallCore): each
  provider client calls `RequestTally.record()` just before it hands a request to its transport, repeats included, and
  `SyncEngine` runs each account's work inside one tally. A new client, or a new place that calls a transport directly,
  must record too, or its requests are missing from the line. The line is written at `SyncReport.logLevel` (notice, so
  the unified log keeps it); do not lower it to info.
- Only `GitHubClient.send(_:decoding:)` repeats a request, and only after 502, 503 or 504 or a 2xx answer whose body
  is not JSON at all (an empty body included): twice at most, after 1 s and 2 s (`retryDelays`). A body still not
  JSON after the last attempt is thrown as `ProviderError.network`. A 401, a rate limit, any other status, GraphQL
  errors in a 200 answer, JSON of the wrong shape (`invalidResponse`) and network errors fail at once, and the GitLab
  client repeats nothing. A 502–504 or a network error that reaches `SyncEngine` counts in
  `FetchStatus.consecutiveFailures`: the first two failed syncs in a row leave the account's state and message as they
  were and write a `QuietFailure` line to the log (provider, kind of error, place in the series, no message), the
  third writes `error` (`SyncEngine.quietFailures`). Keep the quiet period in `FetchStatus`, because Settings, the
  popover, the main window and the widget all read `FetchStatus.state` (see `docs/adr/0016`).
- Filter categories combine with AND, values inside one category with OR. Two deliberate exceptions live in
  `FilterEngine`: a draft that names me as a reviewer passes a review preset even when drafts are off (cloud
  agents cannot mark their pull requests ready), and author logins are compared without a trailing `[bot]`,
  because GitHub GraphQL returns `renovate` where REST returns `renovate[bot]` (`LoginMatch`).
- `ItemFilter.query` is GitHub search syntax read by `SearchQuery` and evaluated **locally** by `FilterEngine`, for
  both providers, and that local reading decides what a preset shows. On GitHub.com `PresetSearchQuery` also sends it,
  with the preset's other fields, as the search that decides what is downloaded; that search must find at least what
  the local reading matches (see `docs/adr/0017`). A space or `AND` is AND, `OR` is OR, AND binds tighter, and
  parentheses nest at most five levels; a leading `-` excludes one term. `-(…)` and a bare `@login` are errors and
  `NOT` is no operator — all checked against GitHub's own search (see `docs/adr/0009`). Commas inside a term are
  OR, which GitHub only honours for `label:`. Only qualifiers `WorkItem` can answer are accepted; anything else is
  a parse error, and an unreadable query matches nothing so a typo cannot widen a preset. Adding a qualifier means
  adding it to `SearchQuery.Qualifier`, to `SearchQueryTests` and to the table in the README, and deciding in
  `PresetSearchQuery` (where the switch stops the build) whether GitHub can answer it at least as wide, with a row in
  `PresetSearchQueryTests`; when it cannot, it stays local. `priority:` is the one qualifier taken from GitHub
  Projects' filter syntax rather than issue search.
- On GitHub.com a regular sync fetches only the presets `SyncSelection` picks, at least one search per preset, account
  and kind, and keeps a `PresetResult` per preset and account; everything else is fetched on open (`syncPresets`).
  GHES and GitLab download everything as before (`ProviderCapabilities.presetSearch`). A change must keep these: the
  search is never narrower than `FilterEngine`; readers of the snapshot learn which accounts search from
  `Snapshot.searchedAccounts` and do not branch on the provider kind; an item missing from a search is `.closed` only
  when `fetchItemStates` confirms it; the first result of a pair or of an edited preset (`selectionFingerprint`)
  reports nothing; a failed search keeps the previous result and a refused query (`PresetSearchFailure`) never changes
  the account's `FetchStatus`; the log (`SyncReport`) holds only counts, with no query or login in it (see
  `docs/adr/0017`).
- The preset JSON of `PresetTransfer` is a public contract (`docs/adr/0013`, README *Sharing presets*): `id`, `name`,
  `query`, `icon`, `sort`, `kinds` under `"version": 1`. Unknown keys are errors, everything is validated before
  anything is written, a paste never deletes, and an export round-trips exactly. A new key or a changed meaning needs
  version 2. The JSON spells `SortOrder` and `ItemKind` by their raw values, so renaming a case breaks pasted files.
- Detail (`GitProvider.itemDetail`) only reads and asks for one item at a time, by repository and number, never inside
  the sync. GitHub splits it into the conversation and, for pull requests, the checks and files, so one can fail
  without the other; every part of `ItemDetail` is its own `Result`, and an error whose path runs through one field
  fails only that part. A refusal is `.missingPermission` (Detail links to the token setup), anything else
  `.failed` (Detail offers Try Again, and `DetailCache` does not keep it). Bots (`authorIsBot`, or a login ending in
  `[bot]`) never count as the latest word; check ids must be unique, names repeat. A provider without Detail keeps the
  default `nil` and says so through `ProviderCapabilities.fetchesItemDetail`. See `docs/adr/0015`.
- `NextStep` and `FilterEngine.explain` are generic on purpose: no labels, logins or habits of one team.
- The Gitwall file (`GitwallFile`, `docs/adr/0014`) is version 2 of that contract: `presets` and `walls`, a tile as
  `{"preset": "<uuid>", "size": "large"}`. Version 1 and bare lists go to `PresetTransfer` unchanged, so they paste
  exactly as before. The same rules hold: unknown keys are errors, everything is checked first, a paste never deletes.
  Tile ids, zoom and rotation stay out of the file. Every export writes each tile's `size`; a missing size reads as
  `medium`.
- `TileView` draws the desktop widgets, so a change to it is a change to every widget. Compare the four demo widgets
  before and after (`--debug-fresh --debug-demo --debug-demo-widgets`, pixel by pixel) and keep WidgetKit out of it.
