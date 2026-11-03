# 15. Detail is read-only and fetched on demand

Date: 2026-11-03

## Context

Gitwall tells you *that* something waits for you; to decide *what* to do about it you had to open the browser. A
click on an item now opens **Detail** next to the list instead: why the item is in front of you, the next step with
the exact link, the latest word of the other side, the pull request's status and what is new since you last looked.
Everything else (description, conversation, files, linked items) is folded below.

The snapshot does not hold most of that. It carries the review, CI and merge state and the size of a change, but no
text of comments, no checks by name, no files and no timeline. Three questions follow: may Detail change anything on
GitHub, where does the extra data come from, and how does Gitwall know what is new for you.

## Decision

### Read-only

Detail never writes. There is no approve, merge, comment or label button; every block links to the exact place on
the provider instead: *Review changes* to `/files`, a failing check to its log, the latest word to that comment.

- **Token scopes.** Writing needs `repo` write access on a classic token or write permissions on a fine-grained
  one. The token guide asks for read-only access everywhere, and many organizations only approve read-only tokens.
  A button that works for some accounts and fails for others is worse than a link that always works.
- **The promise of the App Store description.** It tells people to "use a personal access token with read access",
  and the README recommends a read-only fine-grained token for github.com. Every feature has to work with such a
  token; write actions would not, and from a menu bar app they are one click away from an accidental approval.

### Fetched on demand, one item at a time

`GitProvider.itemDetail(account:token:item:)` asks for one item when Detail shows it; the sync does not change.

- **GitHub** asks two read-only GraphQL queries in parallel, both through `repository(owner:, name:) {
  issueOrPullRequest(number:) }`, so no node id is needed and snapshots written by older builds work:
  1. the conversation: body, the last 20 comments, the last 10 reviews, the last 30 timeline events (comments,
     reviews, commits, labels added and removed, ready for review, review requests, assignments, force pushes) and
     the linked items (issues a pull request closes, pull requests that close an issue);
  2. pull requests only: the checks and statuses of the last commit by name, with their links, and the first 100
     files.
- **Each part fails on its own.** `ItemDetail` holds every part as a `Result`. The second query may fail without the
  first, for the same reason the priority lookup is separate from the lists in
  [ADR 0012](0012-priority-comes-from-a-projects-field-then-labels.md): GitHub refuses a whole query when one field
  is refused. Inside a query, an error whose path runs through one field fails only that part. A refusal
  (`FORBIDDEN`, `INSUFFICIENT_SCOPES`) is a missing permission and Detail links to the token setup; anything else is
  a passing failure. Both offer *Try Again*, which fetches past the cache: a fine-grained token's permissions change
  on GitHub without the token changing.
- **Cost.** Each query cost 1 point of GitHub's hourly 5 000 when measured (see below), and only when someone opens
  an item. Arrowing through a list asks only once the selection rests for 150 ms. `DetailFetcher` shares a fetch
  already in flight; `DetailCache`, owned by the app's one `ItemDetailService`, keeps the last 100 details, each
  valid while the item's `updatedAt` is unchanged. A detail with a passing failure is not kept, so opening it again
  tries again. A missing permission is kept until the account's credential is replaced or the account removed.
- **Changes while it is open.** When a sync gives the item on screen a new `updatedAt`, Detail fetches it again and
  marks what arrived meanwhile.
- **GitLab** has no Detail yet: `ProviderCapabilities.fetchesItemDetail` is false, and Detail shows what the snapshot
  holds plus *Open on GitLab*.

### Our own "seen" instead of GitHub's notifications

"What's new" and the dot in lists compare against the moment you last saw the item in Detail, which Gitwall keeps
itself: `seen.json` in the App Group (`SeenStore`), item id → time. Seen is the time the detail was fetched, recorded
once it has loaded with its timeline while the item is still the one on screen; clicking through a list or a failed
fetch marks nothing. An item without a fetch (sample data, GitLab, no credential) counts after a second on screen. An entry stays while its item is in the snapshot
or was opened in the last 30 days. What's new lists the timeline events by other people after that moment; the first
open of an item lists its last three events. The dot appears only on items you have opened before, when they changed
since.

"Latest word" and *Reply to …* leave bots out (a `Bot` author, or a login ending in `[bot]`): a Codecov report is
not the other side's answer. Every submitted review of someone else counts, a bare approval or change request and
inline-only reviews too, shown by what they were.

GitHub's own read state lives in notifications. GitHub documents their API for classic tokens only (scope
`notifications` or `repo`); fine-grained tokens, which the README recommends for github.com, cannot read them at
all. They also cover only threads you are subscribed to. A dot that works for some accounts and silently not for
others is worse than one Gitwall keeps itself.

## Alternatives considered

- **Writing actions in Detail** (approve, merge, re-run checks). Rejected above; links do the same job without
  write scopes.
- **Widening the sync** to fetch comments, checks and timelines for every item. Every item in every sync, most of
  them never opened, and the list queries would grow past what a fine-grained token may read, taking the whole list
  down with them. Rejected.
- **One query for everything.** Simpler, but a token that may not read check runs would lose the conversation too.
- **Node ids** (`nodes(ids:)`). Needs `WorkItem.nodeID`, which older snapshots and GitLab do not have.
- **GitHub notifications for "what's new".** Rejected above (no fine-grained tokens, only subscribed threads).
- **A Markdown library** for the description and comments. Gitwall has no third-party dependency. Foundation's parser
  with full syntax covers headings, lists, task lists, quotes, code and tables; Gitwall adds `<details>` as a
  collapsible block, hides HTML comments as GitHub does, shows other HTML as its text and turns images into links.

## Checked against GitHub

On 2026-11-03 with a classic OAuth token (`repo`, `read:org`, `read:project`), against public items of
`vapor/postgres-nio` (the fixtures in `GitwallGitHubTests` are these answers):

| Check | Result |
|---|---|
| Conversation query, pull request #686 / issue #499 | answered without errors, cost 1 point each |
| Status query, pull request #686 | 15 check runs by name with links (one failing, one skipped), 9 files, cost 1 point |
| `closedByPullRequestsReferences` on issue #499 | the open pull request #505 |

**Not checked live:** a fine-grained token. GitHub's REST documentation maps pull request files and reviews to
*Pull requests: Read* and comments and timelines to *Pull requests* or *Issues: Read*, which the token guide already
asks for; fine-grained tokens cannot get the *Checks* permission at all. Whether GraphQL then hides check runs from
`statusCheckRollup.contexts`, refuses them, or shows them is not known. Detail handles all three: the checks part
either lists what it got or says the token may not read the checks, and the rest works. The integration test
`ItemDetailIntegration` with `GITWALL_GITHUB_DETAIL=owner/repo#123` answers it for a given token.

## Consequences

- Two requests, about 2 rate-limit points, per pull request opened in Detail; one for an issue. Nothing more per sync.
- Detail needs a token that can read the item, which every account already has; no new scope.
- `seen.json` is new in the App Group. The widget never reads it, and sample data never writes it.
- Clicking an item in the main window or on a wall no longer opens the browser; a double click and ⌘↩ do. The popover
  and the widgets still open the browser, which is quicker than bringing a window forward.
- GitLab gets the snapshot part of Detail only, until its provider implements `itemDetail`.
