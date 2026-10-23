# 12. Priority comes from a GitHub Projects field, then from labels

Date: 2026-10-23

## Context

Gitwall sorts by activity or by creation date. That answers "what moved last", not "what should I do first".
The teams Gitwall is built for keep the answer on their planning board: a GitHub Projects (v2) single-select field
called **Priority** with the options `P0`–`P3` (DX Heroes' *DX Work* board; GitHub's own project templates call the
field Priority too, with `P0`–`P2`). A few repositories carry the same idea as labels `p1`–`p3` instead.

None of that is in the data Gitwall fetches today, and reading it has two costs that the rest of the app does not
have:

- **Another permission.** Projects are not covered by `repo`. A classic token or an OAuth sign-in needs the scope
  `read:project`; a fine-grained token needs the organization permission *Projects: Read*. Tokens and sign-ins made
  before this change have neither.
- **A failure mode that can take the whole list down.** GitHub refuses a GraphQL query outright when a field in it
  needs a scope the token lacks (`INSUFFICIENT_SCOPES`, no `data`), and `GitHubClient` maps that to
  `ProviderError.unauthorized`, which the sync engine turns into *Sign in again*. A field that fails on its own
  (`FORBIDDEN`) is no better: `projectItems` is non-null, so GitHub nulls the enclosing pull request or issue.

## Decision

### Where a priority comes from

1. **A project field named exactly `Priority`**, read with `fieldValueByName(name: "Priority")`. GitHub compares
   the name with case, so `priority` is not found; that is GitHub's rule, and the template name is `Priority`.
2. **Only open projects and items that are not archived** (`projectItems(includeArchived: false)`, `project.closed`).
3. **An item in several projects takes the most urgent value.** If one team calls it P0 and another P2, it is P0
   for whoever looks at it in Gitwall; under-reporting urgency is the worse mistake. No project has to be chosen in
   settings, and the answer does not depend on the order GitHub lists the projects in.
4. **Labels when no project gives a value.** `p0`–`p3`, any case. Several priority labels: the most urgent wins.
5. **What counts as a level**, for an option and a label alike: `P0`–`P3`, any case, alone or followed by a
   character that is not a letter or digit (`P1`, `p2`, `P0 - urgent`, `P1: high`). `P4`, `high`, `priority: low`
   and `high-priority` are not levels. Guessing whether *high* means P0 or P1 would make the sort lie; teams that
   want those in Gitwall can rename the options.

`WorkItem.projectPriority` stores the project value, `WorkItem.priority` computes `projectPriority ?? labels`. The
label rule therefore needs no new fetch, works for snapshots written by older builds, and is the same for both
providers.

### GitLab

GitLab has no single-select field on issues or merge requests, so **labels are the only source** there. GitLab's
*prioritized labels* are left out: they order labels inside one project and say nothing about P0 versus P3.
Scoped labels such as `priority::1` are not read either; `P1` as a label name works.

### How it is fetched

A separate, optional request **after** the item lists, never inside them:

```graphql
nodes(ids: [ …up to 100 node ids… ]) {
  ... on Issue       { id projectItems(first: 10, includeArchived: false) { nodes { project { closed } fieldValueByName(name: "Priority") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } }
  ... on PullRequest { …the same… }
}
```

- The list fragments now ask for each item's `id` (`WorkItem.nodeID`), which every token may read.
- `GitProvider.projectPriorities(account:token:items:)` returns a `PriorityLookup` and **cannot throw**; GitLab uses
  the default, which finds nothing. `SyncEngine` calls it after a successful `fetchItems`.
- A refused scope or permission is `.missingPermission`: items keep only their label priority, the sync stays `ok`,
  and `FetchStatus.projectAccess = .denied` puts a hint on the account in Settings › Accounts.
- Any other failure (network, rate limit, an unexpected answer) is `.failed`: the sync keeps the project
  priorities and the access state from the previous snapshot, so a hiccup does not reshuffle a list sorted by
  priority.

### Sort, query, row

- **Sort by Priority**: P0 first, then P1…P3, then items without a priority; inside a level the oldest created
  first, because the item that has waited longest at the same urgency is the next one to pick up.
- **`priority:` in the preset query** takes `P0`–`P3` and works like every other qualifier: `priority:P0 OR
  priority:P1`, `priority:P0,P1`, `-priority:P3`. It reads `WorkItem.priority`, so it agrees with the sort and the
  row, and the widget gets it for free through `FilterEngine`. This is GitHub Projects' filter syntax rather than
  issue search syntax; GitHub's issue search has no `priority:` qualifier, so this part of a query does not paste
  there.
- **On a row** a small capsule `P0`–`P3` sits before the title, red for P0, orange for P1, grey for P2 and P3. An
  item without a priority shows nothing. A `p1` label that produced the capsule is not repeated among the labels;
  one that contradicts a project value stays visible.

## Alternatives considered

- **`projectItems` inside the list queries.** One request fewer, but any token without the scope would lose the
  whole list (see Context). Rejected.
- **Read every field value and pick the one whose name looks like priority** (`fieldValues(first: 20)`). Finds
  `priority` and `Prio` too, but costs 11 rate-limit points per 100 items instead of 1 (measured below). A field
  named differently can be renamed; a sync that burns a tenth of the hourly budget cannot be fixed by the user.
- **A per-account or per-preset choice of the project.** Exact, but one more setting for a case nobody has yet; the
  most-urgent rule gives the same answer whenever the projects agree.
- **GitHub's issue fields** (organization-level fields on issues, in preview). Not what the teams use today; a
  second source can be added in front of labels later without changing the sort, the query or the row.
- **Mapping words** (`high`, `urgent`, `priority: low`). See rule 5.

## Checked against GitHub

On 2026-10-23 with a classic OAuth token that has `project`, against *DX Work* (DXHeroes, project 3):

| Check | Result |
|---|---|
| `fieldValueByName(name: "Priority")` / `(name: "priority")` on an item set to P2 | `P2` / `null` |
| `nodes(ids:)` with 100 ids, `projectItems(first: 10)` and `fieldValueByName` | cost 1 point |
| The same with `fieldValues(first: 20)` instead | cost 11 points |
| Option names on DX Work / Plantory.ai project | `P0` `P1` `P2` `P3` / `P0` `P1` `P2` |
| Open items on DX Work with a priority | 26 of 143 |

**Not checked live:** the answer to a token without `read:project` (tested with GitHub's documented
`INSUFFICIENT_SCOPES` shape), and what a fine-grained token without *Projects: Read* gets — GitHub may answer
`FORBIDDEN` or simply list no project items. In the second case Gitwall cannot tell, shows no hint and falls back to
labels. For projects owned by a personal account GitHub's guidance is a classic token; fine-grained tokens are only
documented for organization projects.

## Consequences

- One extra request per 100 GitHub items per sync, about 1 rate-limit point each.
- Signing in with GitHub now asks for `read:project`. Accounts that signed in before keep working without
  priorities from projects until they sign in again (Settings › Accounts › … › *Sign in again…*); the hint says so.
- The prefilled classic token link asks for `read:project`. The fine-grained link stays as it was: its
  `organization_projects=read` parameter only applies when the owner is an organization, the link defaults to the
  personal account, and the form could not be checked without signing in again (sudo mode). The README lists
  *Projects: Read-only* as a manual step for organization owners.
- A `config.json` with a preset sorted by priority cannot be read by an older build, as with any new enum value.
