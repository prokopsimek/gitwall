# 16. A gateway error is retried, and two failed syncs stay quiet

Date: 2026-11-19

## Context

A GitHub account in Settings › Accounts showed "Server error 502: bad gateway" and looked disconnected, while the
widgets kept showing old data. The token was fine.

GitHub itself was slow. An organization's pull request search with 100 nodes per page ran for about 10 s on GitHub's
side and then answered 502; with 25 per page it took 5–6 s (see *Checked against GitHub*). Issue nodes are lighter,
because the `Issue` fragment asks for no review requests, reviews, merge state or checks.

One such answer was enough to break the account. `GitHubClient` threw at the first 502, and `SyncEngine` wrote `error`
with the message into the account's `FetchStatus` at the first failed sync. Later the same day GitHub answered a GraphQL
request of the installed build with 200 after about 12 s and a body that was not JSON. The client threw
`invalidResponse` ("corrupted data at : The given data was not valid JSON."), which counted as any other error, so the
account showed it at once, with no repeat and no quiet period. Settings › Accounts, Settings › General, the popover, the
main window and the widget all take an account's health from `FetchStatus.state`, directly or through `AppEnvironment`.

## Decision

### Repeat a gateway error or an answer that is not JSON, and only those

`GitHubClient.send(_:decoding:)` is the one place every GitHub REST and GraphQL request goes through: lists, discovery,
the priority lookup and Detail. It decodes the answer too, so one loop decides about every repeat. A request answered
with 502, 503 or 504 is sent again after 1 s and, if it fails the same way, after another 2 s (`retryDelays`), so it
gets at most three attempts. After each wait the client checks for cancellation, so a sync cancelled meanwhile sends
nothing more. The gateway error of the third attempt is thrown as before.

A 2xx answer whose body is not JSON at all is repeated the same way, with the same waits. Not JSON means that
`JSONSerialization` refuses the body, an empty one included; GitHub's answer of 2026-11-19 was such a body. When the
third attempt gets one too, the client throws `ProviderError.network` with "GitHub sent an answer that could not be
read.", so the quiet period below counts it like a lost connection. JSON of the wrong shape, a missing key or a type
mismatch, stays `invalidResponse` and shows at once, because it would fail the same way again. Each repeat writes one
info line with the status and, for a body that is not JSON, its size in bytes.

Nothing else is repeated. A 401, a rate limit (403 with the limit exhausted, or 429), any other 4xx or 5xx, GraphQL
errors in a 200 answer and JSON of the wrong shape would fail the same way again. Network errors are left to the sync.
`URLSessionTransport` turns every `URLError` but a cancellation into `ProviderError.network`, and the quiet period below
covers it. The GitLab client repeats nothing, because GitLab did not show the problem.

### Two failed syncs in a row stay quiet

`FetchStatus.consecutiveFailures` counts syncs in a row that failed with 502, 503, 504 or a network error, for both
providers. An answer that was still not JSON after the repeats reaches the sync as a network error and counts too. The
first and the second leave the account as it was. A healthy account stays `ok` with no message and its previous
`lastSuccessAt`. An account that already shows an error (sign in again, rate limited, error) keeps that state and
message, so an outage never hides or replaces a problem that is already on screen. The third failure and every one after
it writes `error` with the message, as before. A success, or any other failure, sets the count back to 0, and a 401 or a
rate limit shows at once, as it always did. The account keeps its previous items throughout.

The count lives in `FetchStatus` because every reader listed above takes the account's health from
`FetchStatus.state`, so a state left unchanged there hides the outage everywhere at once. `SyncStatus` dates the data
by the oldest `lastSuccessAt` among accounts in a series, which keeps "Updated …" true while an account rides out an
outage. An account in a series that never succeeded leaves the data undated ("Not updated yet"). Snapshots written
before this change have no `consecutiveFailures` and load with 0.

### A quiet failure is written to the log

A failure that stays quiet leaves nothing on screen, so the unified log is where it shows. Each regular sync writes one
notice line (category `sync`, `QuietFailure`) for every account it rides out, with the provider, the kind of error and the
failure's place in the series, such as `A github account failed quietly (server 502), 1 of 2`. The line holds no
message, because a message can carry a URL or a login. The third failure writes `error` and shows on screen, so it gets
no such line. An on-demand fetch ([ADR 0017](0017-github-presets-are-searched-on-the-server.md)) changes no status and
writes none.

The line is written at the notice level, not at info: the unified log keeps info messages in memory only, so a later
`log show --predicate 'subsystem == "cz.prokopsimek.gitwall"'` or a sysdiagnose would find nothing, while notice
messages are written to disk. At most one such line per failed account and sync, about one sync every 5 minutes, so the
cost is small. Which level the lines have is `SyncReport.logLevel`, which a test asserts; that the system keeps them
on disk is Apple's documented behaviour and was not checked on a running build.

The line of a sync with a selection ("Synced presets of widgets …", `SyncReport`) gets `failed accounts N` when an
account error stopped one or more accounts, a quiet one included; the line of an on-demand fetch always had the count.
A sync in which every account worked writes its line as before. Until now a quietly failed sync read as a success in
the log.

### Page sizes of the two searches

The preset search on GitHub.com (`GraphQLQueries.presetSearch(kind:)`, `search(type: ISSUE_ADVANCED)`) asks for 25
pull requests or 100 issues per page, and its paging stops at GitHub's cap of 1000 results
(`maxPresetSearchResults`). The document and its constants are in `GraphQL.swift`; `GitHubProvider.fetchPresetItems`
sends it ([ADR 0017](0017-github-presets-are-searched-on-the-server.md)).

The `ISSUE` search of organization sources (`GraphQLQueries.search`) stays at 100 per page and three pages
(`searchPageSize`, `maxSearchPages`). GitHub Enterprise Server sends it in every sync. GitHub.com sends it only in a
sync without a selection, that is while the app has never read the widget configurations
(`AppEnvironment.syncSelection()`); with a selection GitHub.com sends the preset search alone. With 25 per page and
the same three pages, GHES would silently drop from 300 to 75 pull requests per organization, and the 502 was
measured on GitHub.com only.

## Alternatives considered

- **Show the error right after the retries.** Three attempts cover one slow answer. When GitHub keeps failing the same
  query for longer, every sync would still mark the account as broken.
- **No retry, only the quiet period.** Each failed sync would leave the data old for a whole sync interval, where a
  repeat after 1 s costs a second.
- **A keepalive or a change to the token refresh.** The token was valid and the account was never disconnected. The
  message only made it look that way.
- **Count the quiet period in `SyncStatus` only.** Settings and the widget read `FetchStatus.state` and would still
  show the error.
- **A new `FetchState` case for an outage.** Every reader of the state would have to change.

## Checked against GitHub

On 2026-11-19 with `gh api graphql`, against GitHub.com:

| Check | Result |
|---|---|
| Pull request search over one organization, 100 nodes per page | 9.6–10.7 s, then 502 |
| The same search, 25 nodes per page | 5–6 s |

The answer that was not JSON came from the unified log of the installed build on the same day: 200 after 11.9 s.

The repeats are covered by `RetryTests`, the quiet period by `SyncEngineTests`, `SyncStatusTests` and, through the real
GitHub client, `NotJSONSyncTests`, and the log lines by `SyncEngineQuietFailureTests`, all with scripted answers.

## Consequences

- An outage that lasts into a third sync in a row shows on that sync with the same message as before. At the default
  interval of 5 minutes (`AppSettings.refreshIntervalMinutes`) that is about ten minutes after the first failed sync.
  Until then the account looks healthy and only the age in "Updated …" grows.
- A failing request takes longer to fail. The waits add 3 s, and each repeat takes as long as the attempt it repeats.
  The search measured above failed after about 10 s, so three attempts and the waits come to more than 30 s. An answer
  that is not JSON after about 12 s costs as much.
- An answer that stays not JSON into a third sync shows as "Network error: GitHub sent an answer that could not be
  read." instead of the decoding error it showed before.
- The unified log tells a quiet sync from a healthy one: a line per account that failed quietly, and `failed accounts`
  in the line of every sync. Neither holds anything but counts, kinds and the provider, and both are written at the
  notice level.
- The `ISSUE` search with 100 per page, the query measured above, still goes to GitHub Enterprise Server in every sync
  and to GitHub.com in a sync without a selection. There the retry and the quiet period are what keep its 502 off the
  screen. With a selection GitHub.com sends only the preset search, 25 pull requests or 100 issues per page.
- The numbers are two constants, `GitHubClient.retryDelays` and `SyncEngine.quietFailures`.
