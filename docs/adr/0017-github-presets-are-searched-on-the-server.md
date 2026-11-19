# 17. GitHub.com presets are searched on the server and fetched when shown

Date: 2026-11-19

Partly supersedes [ADR 0008](0008-preset-queries-use-github-search-syntax-locally.md). On GitHub.com a preset's
fields and query now also go to GitHub, as the search that decides what is downloaded. `FilterEngine` still decides
what the preset shows.

## Context

Until now every account downloaded all open items of its sources in every sync (`GitProvider.fetchItems`), and a
preset was a local filter over that one list. ADR 0008 kept the query local on purpose. A server-side query would
only have worked for organization sources and never for GitLab, and `docs/PLAN.md` says correctness must not depend
on a server prefilter.

On GitHub.com that download was no longer complete. An organization source reads GitHub's `ISSUE` search, three pages
of 100 sorted by last update (`GraphQLQueries.searchPageSize`, `maxSearchPages`), so an organization with more open
issues loses the ones changed least recently. A preset over three organizations showed 9 of the 18 issues that
`gh search` finds; the 9 missing ones were the oldest. Pages of 100 pull requests also made GitHub answer 502 after
about 10 s ([ADR 0016](0016-transient-sync-failures.md)). Downloading everything with smaller pages up to GitHub's cap
of 1000 results would fill the snapshot with items no preset shows, and would still stop at 1000.

A preset already says what it needs. GitHub's `ISSUE_ADVANCED` search, unlike `ISSUE`, evaluates `OR` and parentheses
and gave the same counts as `gh search` for the same presets (see *Checked against GitHub*), so most of a preset can be
asked of GitHub directly. And most presets are not on screen at any moment: only what the widgets, the menu bar, the
notifications and the open windows show needs fresh data in every sync.

## Decision

### What a sync fetches

`SyncSelection.presets(in:widgets:open:shownWall:)` picks the presets a regular sync fetches:

- the preset of each desktop widget, or the first preset for a widget that names none or a deleted one, as the widget
  itself shows;
- the first preset with `showCountInMenuBar`, the one `AppEnvironment.menuBarBadge` counts;
- every preset with at least one notification switched on, because a notification can only fire for a change a sync
  saw;
- the preset the popover or the main window shows while one of them is on screen;
- the presets of the tiles on the wall the Walls window shows.

Each source keeps its own set, so the log line can say why the sync fetched what it did. A window counts as on screen
while it is open and not in the Dock, also behind other windows.

Before each sync `AppEnvironment.syncSelection()` reads the widget configurations through
`WidgetCenter.getCurrentConfigurations` (`AppEnvironment.widgetPresets()`), which is why
`GitwallWidget/PresetIntent.swift` is compiled into the app target as well. When WidgetKit cannot answer, the app uses
the configurations it read last in this run. When it never could, it syncs without a selection, and every account
downloads everything as before.

A widget removed from the desktop can stay in WidgetKit's configurations after it is gone. On 2026-11-19 a large widget
removed with Remove Widget at 17:31 left the desktop at once: its render session ended, and both the desktop's list of
widgets and chronod's stored host configuration named only the seven that were left. Yet `getCurrentConfigurations`
kept returning it and WidgetKit kept asking the extension for its timeline after every reload, still at 19:06 (95
minutes later), also after Gitwall was quit and opened again. `WidgetInfo` says nothing about whether a widget is on
screen, so the app cannot tell such a configuration from a placed widget. Until macOS lets go of it, its preset is
searched in every sync (at least one search per kind) and counted under widgets in the log line, which then reads one
more than the desktop shows.

Every other preset is fetched when a window opens it. `AppEnvironment.fetchOnOpen(_:)` runs when the popover or the
main window opens or switches preset, when the Walls window opens and when another wall comes up, by hand or by
rotation. It fetches only the presets for which `PresetFreshness.needsFetchOnOpen` holds. That is the case when a
searching account in the preset's scope has no result for its current selection, or last asked GitHub longer ago than
the sync interval. The time asked is the later of the last fetch and the last refused query, so a refused query is
tried again at most once per interval. Meanwhile the window shows the last result with its fetch time. Only a preset
that waits (see *A result per preset and account*) shows a spinner, also when its GitLab part has items, and a widget
shows "Waiting for sync".

### Who searches

`GitProvider.fetchPresetItems(account:token:search:)` fetches one preset in one account, from a `PresetSearch` to a
`PresetFetch`. Only an account for which `capabilities(for:)` sets `ProviderCapabilities.presetSearch` does it, and
`SyncEngine` asks only that and does not look at the provider kind. `GitHubProvider` sets it for github.com alone
(`Account.isCloudInstance`). GitHub Enterprise Server and GitLab keep `fetchItems` and download everything in every
sync, exactly as before; GHES keeps the `ISSUE` search with three pages of 100. Whether GHES accepts `ISSUE_ADVANCED`
is not known, and a refusal there would break every GHES account.

### The query

`PresetSearchQuery` in GitwallGitHub writes one query per item kind:

```
is:pr is:open (org:acme OR repo:acme/web) archived:false <filter terms> sort:updated-desc
```

- The account's organizations and repositories, or the repositories of the preset's scope, go in one OR group in
  parentheses, because two `org:` side by side are AND.
- `archived:false` is in every query ([ADR 0007](0007-archived-repositories-are-never-listed.md)).
- Last activity sorts as `sort:updated-desc`, newest and oldest created as `sort:created-desc` and `sort:created-asc`,
  so a search cut off at the cap starts with the right items. GitHub cannot sort by priority, so a priority preset
  sends `sort:updated-desc`, a fixed order that keeps pages from shifting while they are read.
- A preset without a filter sends kind, state, sources, `archived:false` and the sort, and nothing else.

The preset's fields become top-level AND terms:

| Preset | Sent to GitHub |
|---|---|
| `relations`: authored by me, review requested from me, assigned to me | `author:@me`, `review-requested:@me`, `assignee:@me`; several as one OR group |
| `authorsAny` | `(author:x OR author:app/x …)`, the login without `[bot]` |
| `labelsAny` / `labelsNone` | `(label:"a" OR label:"b")` / `-label:"a"` |
| `updatedWithinDays` | `updated:>=` the day before the cutoff's UTC date |
| `milestone` | `milestone:"x"` |
| `author:`, `assignee:`, `reviewed-by:`, `review-requested:` in the query | the login in both forms, `x` and `app/x` |
| `involves:x` in the query | `involves:`, `reviewed-by:` and `review-requested:` for `x`, each in both forms, as one OR group |
| `label:`, `milestone:`, `repo:`, `org:` in the query | as written, labels and milestones quoted |
| `is:draft`, `-is:draft` in the query of a pull request search | as written |

A comma list inside a term goes out as an OR group, or as one exclusion per value when the term is negated. Inside
the query an AND keeps the terms it can translate, an OR is sent only when every branch can be, and a negated term only
when its translation is exact.

Some fields are never sent, so `FilterEngine` alone decides them. These are `includeDrafts` with its exception for a
draft that asks for my review (`includeDraftsRequestingMyReview`), `reviewStates`, `ciStates`, `mergeStates` and
`text`. From the query, bare words stay local, because GitHub matches whole words and Gitwall any part of the title,
and so do `priority:`, `authorsNone` and every negated login except `-author:@me` and `-assignee:@me`. `is:` and
`type:` other than draft are decided before the search, for the kind it runs, because GitHub reads them as a choice of
kind and state for the whole search (`is:pr -is:pr` returns every item). A filter that matches nothing locally sends
no terms.

Each of these choices can only widen the search beyond the local filter. The reasons come from GitHub's answers.
GraphQL gives a GitHub App's login as its bare slug, and `reviewed-by:<slug>` finds nothing while
`reviewed-by:app/<slug>` does. A negated login GitHub does not know, a typo or a deleted account, empties the whole
search, and which logins GitHub knows cannot be told without a request per login. GitHub's `reviewed-by:` sees every
review where the snapshot keeps the latest ones, and its `review-requested:` includes requests to the person's teams,
so excluding either on the server could hide what the preset shows.

### Length, paging and sources

- Gitwall keeps a query within 4000 characters (`GraphQLQueries.maxPresetSearchQueryLength`, counted in UTF-8 bytes);
  GitHub accepted and fully evaluated one of 4273, and answered 500 to a later one over 4000. A query that does not fit
  is split by its sources into several searches. When the filter does not fit beside even the longest source alone,
  its longest top-level terms are left out until it does. A long preset therefore still syncs and downloads more. The
  limit of 256 characters stays for the `ISSUE` search.
- Pages hold 25 pull requests or 100 issues (ADR 0016), up to GitHub's cap of 1000 results
  (`maxPresetSearchResults`). A result is complete when GitHub had no further page and counted no more than 1000.
  Above that the unified log gets a warning and the count shows "+". At the cap GitHub itself stops: the tenth page
  of 100 says there is no next page, and a request with its cursor returns no nodes.
- Only items from the search's own sources are kept. When GitHub knows none of the sources of the OR group, it drops
  the group and searches all of GitHub.
- Review requests addressed to a team are resolved once per `fetchPresetItems`, as `fetchItems` does once per fetch.

### A result per preset and account

`Snapshot` keeps one list of items and, beside it, `presetResults` with one `PresetResult` per pair of preset and
account. A result holds the ids of the items found, `fetchedAt`, GitHub's `totalCount`, `isComplete` and the preset's
`selectionFingerprint`, and a `PresetQueryFailure` when the last search was refused. `Snapshot.searchedAccounts` names
the accounts whose items go by these results. A sync without a selection names none, so every preset reads all items
as before. `schemaVersion` is 2. A snapshot of version 1 loads with no results and no searched accounts, without a
migration.

- A sync turns each search into a `PresetOutcome`, and `PresetResult.merged(_:with:at:)` folds them in. A fetched
  search replaces the pair's result. A refused one keeps the previous items, fetch time and count and records the
  failure. A failed account leaves the result as it was. A pair the sync did not search keeps its result.
- `Preset.selectionFingerprint` is the SHA-256 of a canonical JSON of the filter with its query, the kinds, the scopes
  and the sort. When any of them changes, `Snapshot.result(for:account:)` returns nil and the preset reads as never
  fetched until it is searched again. A field added to `ItemFilter` is part of the fingerprint without a change there,
  so after such an update every preset reads as never fetched once.
- Results of deleted presets and removed accounts are dropped when the next sync writes the snapshot.
- An item stays in the snapshot while a search of this sync returned it or some result still holds it. A preset that
  left the screen keeps its last result and its items.
- What a preset shows comes from `PresetFreshness`: in each searched account the items of its own result, in every
  other account all items, then `FilterEngine`. Its count is the length of that list (`PresetCountDisplay`). It shows
  "+" when a search stopped before GitHub's count. After a refused query it shows "Query failed" with the time of the
  last result. A preset waits, with "–" and no fetch time, while any of its searched parts has no result for its current
  selection; a preset without a searched part waits until one of its accounts first synced. A preset over GitHub.com and
  GitLab therefore shows "–" until its GitHub.com part has a result, because a count of the GitLab part alone would look
  like the count of the whole preset. From then on it is dated by its older part. The app reads it through
  `AppEnvironment.presetCount(for:)` in the popover, the main window's sidebar, Settings › Presets, onboarding and the
  Walls window. The widget reads the same snapshot and learns from `searchedAccounts` which accounts search. It does
  not look at the provider kind.

### Items that leave a result

A search returns only the open items that match, so an item missing from a fresh result may be closed, merged, deleted
or no longer matching. After the searches of an account, the items that left a fresh result whose pair had an
earlier result of the same selection, and that no search of this sync returned, go to one
`GitProvider.fetchItemStates(account:token:items:)`. An item that only an older result of another preset still holds
is asked about too. `GitHubProvider` asks `nodes(ids:)` in batches of 100, with `state` and the fragments of the
lists, and answers with an `ItemState`:

- `closed` or `merged`: the item leaves every result of the account and the snapshot, and the diff reports one
  `.closed` ("Closed or merged"), as before.
- `notFound`, deleted or no longer visible to the token: it leaves them too, without a notification.
- `open`: the item gets GitHub's current data and stays where a result holds it.
- no clear answer, or a failed lookup: nothing changes and nothing is reported; the log gets a count.

`SearchFindings` carries this to `SnapshotDiff.changes(from:to:accounts:searches:)`. For a searching account, an item
that left the snapshot is `.closed` only when the lookup confirmed it. An item that joined is news only when a result
fetched now had an earlier result of the same selection. The first result of a pair, the first sync after this change
and the first search after a preset was edited are a baseline. They send no notification and set no "new" dot.
Accounts that download everything keep the old rules of the diff.

### Failures

- An account error (a refused token, a rate limit, a gateway error or an answer that is not JSON after the repeats, no
  connection) stops the account's remaining searches in this sync. A refused token first gets one silent refresh per
  sync and the search is sent again, as in a full fetch. The account keeps every item and result, no priorities are
  read, and its `FetchStatus` follows the quiet period of ADR 0016.
- A search GitHub refuses on its own, GraphQL errors in a 200 answer or a status of 400 or 422
  (`PresetSearchFailure`), stays with its preset as a query failure, and the next search runs. It never changes the
  account's `FetchStatus`. GitHub does not refuse a malformed query with an error: an unclosed parenthesis or an
  unknown qualifier comes back as 200 with no results (see *Checked against GitHub*). So "Query failed" comes only
  from GraphQL errors, 400 or 422. Gitwall never sends such a query anyway, because `SearchQuery.parse` rejects it,
  the preset matches nothing, and `PresetSearchQuery` sends none of an unreadable query.
- The account is `ok` with a new `lastSuccessAt` once at least one search succeeded and none ended in an account
  error. When only refused searches ran, or none of its presets was selected, it keeps the status it had.
- After the searches, the project priorities ([ADR 0012](0012-priority-comes-from-a-projects-field-then-labels.md))
  are read once, over everything the searches found and the lookup refreshed.

### Fetch on open and one fetch at a time

`SyncEngine.syncPresets(_:)` fetches the presets a window opens with the same searches, lookup, merge and diff as a
sync. A change found on open is reported as a sync would report it, and a preset's first result reports nothing. It
changes no account's `FetchStatus` and leaves `Snapshot.fetchedAt` as it was, because opening a window must not make
an account look broken. One sync or on-demand fetch runs at a time. Fetch requests that wait at the same time run as
one fetch.

Each sync with a selection and each on-demand fetch writes one line to the unified log (`SyncReport`, category `sync`)
with the presets per source, the searches, requests and items, and the duration, and with the accounts an account error
stopped (a sync with a selection only when there were any; see ADR 0016 for the line of a quiet failure). Queries carry
logins, so no query, login or name ever goes to the log.

### What a change must keep

- The search is never narrower than the local filter. Whatever GitHub cannot answer at least as wide stays local.
  A narrower search hides items without a trace, and `docs/PLAN.md`'s rule that correctness must not depend on a server
  prefilter now rests on this alone.
- `FilterEngine` decides what a preset shows, over the items of its own result, in the widget, the windows and the
  counts alike.
- Whether an account searches comes from `ProviderCapabilities.presetSearch` in the app and from
  `Snapshot.searchedAccounts` in every reader of the snapshot. Nothing branches on the provider kind.
- Only a confirmed state from `fetchItemStates` reports `.closed`. An item missing from a search may just no longer
  match.
- A first result, of a new pair or of an edited preset, is a baseline and reports nothing.
- A failed search never empties a result, and a refused query never changes the account's `FetchStatus`.
- The log holds counts only. Queries carry logins and stay out of it.

## Alternatives considered

- Download everything up to the cap of 1000, with smaller pages. It would end the cut at 300 issues, but it downloads
  items no preset shows, about 20 requests and 100 s per sync by an estimate, and still stops at 1000.
- Download everything now and search per preset in a later release. The same download in the meantime, for a change
  that was coming anyway.
- Fetch every preset in every sync. Every count would always be fresh, but every preset would cost its searches. A
  preset that is not selected shows its last known count and the time of it instead.
- Fetch only the widgets' presets. Nobody opens the menu bar icon to refresh its count, and a notification needs a
  sync that saw the change.
- Report an item that left a result as closed, report nothing, or add an event for leaving a preset. An item that
  stops matching is not closed. Reporting nothing would lose real closes. A new event would change who gets notified.
- Send negated logins after checking each one over REST. That is one request per login and sync, to save downloading
  a few more items.
- A switch in Settings. The change holds for every GitHub.com account, and one more option would only let someone keep
  the incomplete download.
- `ISSUE_ADVANCED` on GitHub Enterprise Server too. Whether GHES has it is not known, and a refusal would break the
  account.
- Keep the `ISSUE` search. It evaluates neither `OR` nor parentheses, and a preset query with
  `(author:… OR author:…)` returned 0.

## Checked against GitHub

On 2026-11-19 with `gh api graphql` against GitHub.com, `search(type: ISSUE_ADVANCED)` unless the row says otherwise.
The first rows ran over organizations of a real account and are given as counts only.

| Check | Result |
|---|---|
| A preset query with `(author:… OR author:…)` over one organization, `search(type: ISSUE)` | 0, because `OR` and parentheses are not evaluated |
| The same query, one organization / two organizations in an OR group | 33 / 35; the two-organization count matches `gh search` |
| A preset query over three organizations, four authors and two labels or an assignee | 18, as `gh search` finds; the snapshot of the full download held 9 |
| `-is:draft`, `-author:…` and two levels of parentheses | evaluated |
| One search with `first: 1` | 1 point of the GraphQL rate limit |
| A query of 4273 characters with 120 `OR`, in `cli/cli` | accepted and evaluated to the end; `-label:enhancement` after the 120 `OR` takes the count from 290 to 289 |
| `org:cli org:github` / `(org:cli OR org:github)` | 0 / 909 |
| An unknown user, app, repository or organization | 0 results, no error |
| `author:dependabot` / `author:app/dependabot` / `author:dependabot[bot]`, in `cli/cli` | 0 / 462 / 462 |
| `reviewed-by:<app>` / `reviewed-by:app/<app>`, in a public repository | 0 / 38 |
| `is:pr -is:pr` | every item, so `is:` chooses kind and state for the whole search |
| `-author:` with a login GitHub does not know | 0, the whole search comes back empty |
| `PresetSearchQueryLiveTests` with a token, over 60 pull requests and 200 issues of `cli/cli` (311 s) | 35 rows of the translation table. In 32 the local filter's result is a subset of GitHub's answer, 3 skipped (one row with `@me`, two with a milestone the repository lacks), none failed |
| `PresetSearchQueryLiveTests` with the GitHub CLI's classic token (`repo`, `read:org`), over 126 pull requests and 208 issues of a public repository with milestones and two public repositories of the token's owner (594 s) | 46 rows. In 42 the local filter's result is a subset of GitHub's answer, none failed. The 12 rows with `@me` and the relations (each relation alone, all three as one OR group, `author:`, `review-requested:`, `assignee:` and `involves:@me`, `-author:@me`, `-assignee:@me`) each kept local items, 1 or 2, and 125 and 207 for the two exclusions. The two milestone rows kept 24 issues each. The two rows with a bot reviewer were skipped, because this data has no bot reviewer; they passed in the run over `cli/cli`. The query with terms that stay local (no `priority:P1` item in this data) and the unreadable query (nothing by design) kept no local item, so the table test is what covers them |
| A preset search for pull requests, `first: 25` / for issues, `first: 100` | `rateLimit.cost` 1, about 5.7 s / cost 2, about 5 s |
| `nodes(ids:)` with 100 ids, 80 issues and 20 pull requests of `cli/cli` | cost 5, 3.5 s, no node null |
| `fetchItemStates` (`ItemStateLiveTests`) with 150 ids of open items a fetch had just returned, 75 pull requests and 75 issues, with the same token and repositories as the row above | two batches of 100, all 150 open and of the kind they were fetched as, none closed, missing or unanswered; 16.1 s |
| `PresetSearchQueryLiveTests` and `ItemStateLiveTests` with a fine-grained token, read-only *Commit statuses*, *Contents*, *Issues*, *Metadata* and *Pull requests*, repository access `prokopsimek/gitwall` only, over the three public repositories of the classic run above (331 s) | every line the same as with the classic token: 46 rows, 42 subsets, none failed, the 12 rows with `@me` and the relations and both milestone rows included. `fetchItemStates`: 150 ids in two batches, all open and of their kind; 11.5 s |
| The same two suites with the same fine-grained token, over 60 pull requests and 200 issues of `cli/cli` (235 s) | 46 rows, 32 subsets, none failed, both rows with a bot reviewer included. 12 rows kept no local item: the ten `@me` and relation rows that need an open item of the token owner, who has none there, and the two that keep none in the classic run either. 2 skipped, no milestone. `fetchItemStates`: 150 ids, 60 pull requests and 90 issues, in two batches, all open and of their kind; 10.0 s |
| The same two suites and both `Integration` suites with the same fine-grained token, `GITWALL_GITHUB_REPO=prokopsimek/gitwall` | the identity call, discovery (156 repositories, no organization), the open pull requests of `apple/swift` with their states, and Detail of a public pull request and issue with every part, checks included, passed. `prokopsimek/gitwall` answered with no open item, so the two live suites and the test of the configured repository stopped at their check for data, not at a refusal. Over a public repository of the token's owner with 12 open items that test passed, and the priority lookup answered with no priority and no refusal |
| `repo:cli/cli (is:pr` / `repo:cli/cli frobnicate:1` | 200, no `errors`, `issueCount` 0 |
| Six levels of parentheses / a trailing `AND` | 200 with results |
| A trailing `OR` | 502, twice, after about 11 s each |
| A query over 4000 characters | 500 |
| `is:issue is:open archived:false repo:microsoft/vscode` (`issueCount` 18496) in pages of 100 | pages 1–10 hold 100 nodes each, page 10 has `hasNextPage` false, an 11th request with its cursor returns 200 and 0 nodes |

`ISSUE_ADVANCED` accepted six levels of parentheses where `SearchQuery` allows five, so the local parser is the stricter
one. Gitwall sends none of the malformed queries above, and no query over 4000 characters (see *Failures* and *Length,
paging and sources*).

`PresetSearchQueryLiveTests` and `ItemStateLiveTests` run only with `GITWALL_GITHUB_TOKEN`. `GITWALL_GITHUB_REPO` takes
several repositories separated by commas. The account learns the token owner with the same identity call the app makes,
so `@me` and the relations mean the same person on both sides. A row whose local result is empty proves nothing and
counts as "local 0", not as passed. Both print counts only.

Paging, splitting, merging, selection, the lookup and the diff are covered by `PresetSearchQueryTests`,
`PresetFetchTests`, `ItemStateTests`, `SyncSelectionTests`, `PresetResultMergeTests`, `PresetFreshnessTests`,
`SyncEnginePresetSearchTests`, `SyncEngineItemStateTests`, `SyncEngineTurnTests` and `SnapshotDiffSearchTests`, with
scripted answers and fixtures that use invented names.

Token permissions were checked against GitHub's documentation on 2026-11-19. `GET /search/issues` is in the list of
REST endpoints available to fine-grained personal access tokens, and the list of permissions per endpoint names no
permission for it. The REST documentation says a search returns only what the token can access. The GraphQL
documentation says the data requested decides the permissions needed. The search returns issues and pull requests,
read with *Issues* and *Pull requests*, and `nodes(ids:)` reads `state` on the same objects, so the token guide in the
README asks for nothing new. The live runs with a fine-grained token with the README's permissions (see the table)
agree: GitHub answered `search(type: ISSUE_ADVANCED)` and `nodes(ids:)` over the repositories of the classic run with
the same items as for the classic token, and refused no request.

## Consequences

- A sync on GitHub.com sends, for each selected preset, one search per kind (more when a query is split), and one
  lookup per account when items left a result. A preset nobody sees costs nothing until it opens. The first sync with
  a selection on a real configuration sent 6 searches and 14 requests and kept 355 items.
- The searches of an account run one after another. On 2026-11-19 a regular sync with 14–17 requests in a row took
  90–102 s (4–8 s per request), within the default interval of 5 minutes.
- Presets that are not selected show their last known count, with its time in the tooltip, and "–" until every
  searched part has its first result. "+" shows in the popover, the sidebar, Settings › Presets and onboarding; widgets
  and wall tiles show the plain count, because `TileView` takes one.
- The first sync after the update replaces the downloaded items of GitHub.com accounts with preset results. It reports
  nothing, and items that no selected preset holds leave without a notification.
- Editing a preset's filter, kinds, scopes or sort shows it as never fetched until its next search. Its old result and
  items stay in the snapshot until that search replaces them or the preset is deleted.
- A new `ItemFilter` field is not sent until `PresetSearchQuery` learns it, so the search is only wider. A new query
  qualifier stops the build at the switch in `PresetSearchQuery`; when GitHub cannot answer it at least as wide, it
  stays local.
- Whatever stays local widens the search. Presets that rely on the text field, `priority:`, review states or
  `authorsNone` download more and reach the cap of 1000 sooner. Above the cap the rest of the preset is missing, and a
  priority preset, sorted by GitHub by last update, may miss its most urgent items.
- A source GitHub does not know, such as a renamed or deleted repository in a scope, makes GitHub search all of
  GitHub. That costs up to 40 pages whose items are thrown away, and the result is marked incomplete.
- A page that comes with GraphQL errors beside its results, such as nodes of an organization the token is not
  authorized for with single sign-on, leaves the result complete. Its missing items go unnoticed apart from a line in
  the log.
- GitHub Enterprise Server and GitLab accounts behave as before.

Open points, marked NEOVĚŘENO (not verified):

- NEOVĚŘENO: the cap of 1000 with pull requests in pages of 25, at the 40th page. It was checked with issues in pages
  of 100 (see *Checked against GitHub*).
- NEOVĚŘENO: the GraphQL rate-limit cost of the team lookup that each preset fetch runs once. A preset search and a
  `nodes(ids:)` batch were measured (see *Checked against GitHub*).
- NEOVĚŘENO: a sync cancelled while it waits for a retry writes `error` with a cancellation message for the account,
  as a sync cancelled during a request did before; whether this ever shows on screen.
- NEOVĚŘENO: `totalCount` adds up the counts of a split search. When its source groups overlap, such as an
  organization in one and a repository of it in another, an item counts twice and the preset can be marked incomplete
  for nothing.
- NEOVĚŘENO: a search and a lookup with a fine-grained token on a private repository. On 2026-11-19
  `PresetSearchQueryLiveTests`, `ItemStateLiveTests` and both `Integration` suites ran with a read-only fine-grained
  token with the README's five permissions, over public repositories: GitHub accepted `ISSUE_ADVANCED` and
  `nodes(ids:)` from it, answered with the same items as for the classic token and refused nothing (see *Checked
  against GitHub*). Every token may read public repositories, so this does not show that *Issues* and *Pull requests*
  suffice where they are what grants access; the repository the token was granted has no open item.
- NEOVĚŘENO: whether GitHub Enterprise Server accepts `ISSUE_ADVANCED`, which would let it search per preset too.
- NEOVĚŘENO: what makes WidgetKit drop the configuration of a removed widget (see *What a sync fetches*). Quitting and
  opening Gitwall did not; a restart of chronod or a new login has not been tried.
