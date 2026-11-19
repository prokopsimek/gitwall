# 16. A gateway error is retried, and two failed syncs stay quiet

Date: 2026-11-19

## Context

A GitHub account in Settings › Accounts showed "Server error 502: bad gateway" and looked disconnected, while the
widgets kept showing old data. The token was fine.

GitHub itself was slow. An organization's pull request search with 100 nodes per page ran for about 10 s on GitHub's
side and then answered 502; with 25 per page it took 5–6 s (see *Checked against GitHub*). Issue nodes are lighter,
because the `Issue` fragment asks for no review requests, reviews, merge state or checks.

One such answer was enough to break the account. `GitHubClient` threw at the first 502, and `SyncEngine` wrote
`error` with the message into the account's `FetchStatus` at the first failed sync. Settings › Accounts, Settings ›
General, the popover, the main window and the widget all take an account's health from `FetchStatus.state`, directly
or through `AppEnvironment`.

## Decision

### Repeat a gateway error, and only that

`GitHubClient.send(_:)` is the one place every GitHub REST and GraphQL request goes through: lists, discovery, the
priority lookup and Detail. A request answered with 502, 503 or 504 is sent again after 1 s and, if it fails the same
way, after another 2 s (`retryDelays`), so it gets at most three attempts. After each wait the client checks for
cancellation, so a sync cancelled meanwhile sends nothing more. The gateway error of the third attempt is thrown as
before.

Nothing else is repeated. A 401, a rate limit (403 with the limit exhausted, or 429), any other 4xx or 5xx and GraphQL
errors in a 200 answer would fail the same way again. Network errors are left to the sync. `URLSessionTransport`
turns every `URLError` but a cancellation into `ProviderError.network`, and the quiet period below covers it. The
GitLab client repeats nothing, because GitLab did not show the problem.

### Two failed syncs in a row stay quiet

`FetchStatus.consecutiveFailures` counts syncs in a row that failed with 502, 503, 504 or a network error, for both
providers. The first and the second leave the account as it was. A healthy account stays `ok` with no message and its
previous `lastSuccessAt`. An account that already shows an error (sign in again, rate limited, error) keeps that state
and message, so an outage never hides or replaces a problem that is already on screen. The third failure and every
one after it writes `error` with the message, as before. A success, or any other failure, sets the count back to 0,
and a 401 or a rate limit shows at once, as it always did. The account keeps its previous items throughout.

The count lives in `FetchStatus` because every reader listed above takes the account's health from
`FetchStatus.state`, so a state left unchanged there hides the outage everywhere at once. `SyncStatus` dates the data
by the oldest `lastSuccessAt` among accounts in a series, which keeps "Updated …" true while an account rides out an
outage. An account in a series that never succeeded leaves the data undated ("Not updated yet"). Snapshots written
before this change have no `consecutiveFailures` and load with 0.

### Page sizes of the two searches

The preset search on GitHub.com (`GraphQLQueries.presetSearch(kind:)`, `search(type: ISSUE_ADVANCED)`) asks for 25
pull requests or 100 issues per page, and its paging stops at GitHub's cap of 1000 results
(`maxPresetSearchResults`). The document and its constants are in `GraphQL.swift`; the request that sends it comes
with a later change.

The `ISSUE` search of organization sources (`GraphQLQueries.search`), which GitHub Enterprise Server keeps, stays at
100 per page and three pages (`searchPageSize`, `maxSearchPages`). With 25 per page and the same three pages, GHES
would silently drop from 300 to 75 pull requests per organization, and the 502 was measured on GitHub.com only.

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

The repeats are covered by `RetryTests`, the quiet period by `SyncEngineTests` and `SyncStatusTests`, all with
scripted answers.

## Consequences

- An outage that lasts into a third sync in a row shows on that sync with the same message as before. At the default
  interval of 5 minutes (`AppConfig.refreshIntervalMinutes`) that is about ten minutes after the first failed sync.
  Until then the account looks healthy and only the age in "Updated …" grows.
- A failing request takes longer to fail. The waits add 3 s, and each repeat takes as long as the attempt it repeats.
  The search measured above failed after about 10 s, so three attempts and the waits come to more than 30 s.
- Organization sources on GitHub.com still send the `ISSUE` search with 100 per page, the query measured above. Until
  they use a smaller page, the retry and the quiet period are what keep its 502 off the screen.
- The numbers are two constants, `GitHubClient.retryDelays` and `SyncEngine.quietFailures`.
