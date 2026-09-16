# 8. Preset queries use GitHub search syntax, evaluated locally

Date: 2026-09-16

## Context

`ItemFilter` grew one field per idea: `labelsAny`, `labelsNone`, `authorsAny`, `authorsNone`, `milestone`,
`text`. Every field is a flat list whose values combine with OR, and the categories combine with AND. That
shape cannot express "assigned to me **and** to one of my three agents": it needs AND *inside* one category,
and there was no assignee field at all — only the binary `Relation.assignedToMe`.

Adding `assigneesAll` / `assigneesAny` / `assigneesNone`, and the same three for labels and reviewers, would
have been nine more fields, nine more rows in a settings pane that was already too cramped to type into, and
still nothing for the tenth idea.

## Decision

One free-form `ItemFilter.query`, written in GitHub's search syntax and parsed by `SearchQuery` in GitwallCore.

Three rules, all of them GitHub's
([searching issues and pull requests](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests)):

- terms combine with AND, so a repeated qualifier is AND — `assignee:a assignee:b`
- comma separated values inside one term combine with OR — `label:bug,security`
- a leading `-` excludes — `-author:renovate`

`assignee:prokopsimek assignee:franta-dxh,lumir-sokol,tom-gilsky` is therefore the original
`(me AND franta) OR (me AND lumír) OR (me AND tom)`, factored out to `me AND (franta OR lumír OR tom)`.

**No `AND` / `OR` / `NOT` keywords and no parentheses.** GitHub does not document them, and inventing them
would put two syntaxes in one field. Every query that cannot be factored this way is out of reach on purpose.

**Evaluated locally**, over the snapshot, never sent to a server. `docs/PLAN.md` already requires that
correctness must not depend on server-side prefiltering, and server-side would only work for GitHub
organization sources — not for watched repositories and not for GitLab at all.

**Only qualifiers the snapshot can answer**: `assignee`, `author`, `label`, `milestone`, `reviewed-by`,
`review-requested`, `involves`, `repo`, `org`, `is`, `type`, plus bare words for the title, the repository and
`#number`. `mentions:`, `commenter:` and `comments:` are rejected rather than silently ignored, because
`WorkItem` does not carry that data. Date qualifiers are left out for now: GitHub uses absolute dates, the
"Updated within" picker covers the common case, and a made-up relative form would look like GitHub and not be.

**A query that cannot be read matches nothing.** Matching everything would let one typo silently flood a
widget; zero results plus the parser's message under the field points straight at the mistake.

## Consequences

- The existing fields stay. They are the quick path, they keep older `config.json` files loading, and the query
  is simply one more category AND-ed with them.
- `SearchQuery` is parsed once per preset in `FilterEngine.items(matching:)` and `counts(for:)`, not once per
  item. `SnapshotDiff` parses per call, which is fine for the handful of changes it sees.
- The widget gets this for free: it already runs the same `FilterEngine` over the same snapshot.
- The comma-OR is stretched beyond what GitHub documents. GitHub only writes it down for `label:`; Gitwall
  applies it to every qualifier, which is what makes the factored form fit on one line.
- Anyone who learns the field learns GitHub's syntax, not ours — and a query that works here mostly works when
  pasted into GitHub's own search box.
