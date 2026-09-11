# 7. Archived repositories are never listed

Date: 2026-09-11

## Context

Pull requests and issues from archived repositories showed up in presets and widgets. Nothing in an archived
repository can be merged, closed or reviewed, so those rows only pad the queue that Gitwall exists to keep
short. GitHub organization sources already excluded them (`archived:false` in the search query) and GitLab
group connections do the same on their own (`includeArchived` defaults to false), so the noise came from
explicitly watched repositories and projects.

## Decision

Drop them at the source, with no setting to bring them back.

- GitHub asks for `isArchived` alongside `nameWithOwner` in the repository queries; an archived repository is
  skipped before mapping and is not paginated.
- GitLab selects `archived` on the `project(fullPath:)` root. Groups have no such field and need none, so the
  group query never passes `includeArchived`.
- The repository picker no longer offers archived repositories. One that is already watched stays in the list,
  otherwise it could never be unticked (`RepositoryPicker` in GitwallCore).

The alternative was a flag on `WorkItem` plus a filter in the preset editor. It was rejected: it would add a
field to the model and to `snapshot.json` to support a switch nobody asked for, and archived items are noise in
every preset, not in some of them.

## Consequences

- `WorkItem`, `ItemFilter`, `FilterEngine` and the snapshot schema are untouched, so there is no migration.
- Someone who watches an archived repository today sees its items disappear at the next sync. `SnapshotDiff`
  reads a vanished item as closed, so that one sync can deliver a burst of "closed" notifications. It happens
  once per such account; avoiding it is what the rejected alternative would have cost the model.
- A repository that is archived later simply stops contributing at the next sync, which is the same behaviour
  as losing access to it.
- Anyone who really wants to see an archived repository has to open it on GitHub or GitLab.
