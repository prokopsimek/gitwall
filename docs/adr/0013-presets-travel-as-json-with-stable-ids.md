# 13. Presets travel as JSON with stable ids

Date: 2026-11-02

## Context

Prokop keeps his presets outside Gitwall, as a JSON file in another repository, next to the agents whose work they
watch. Setting them up in Gitwall meant clicking each one together: the query could be pasted into the *Query*
field ([ADR 0008](0008-preset-queries-use-github-search-syntax-locally.md),
[ADR 0009](0009-preset-queries-accept-and-or-and-parentheses.md)), but the name, the icon, the sort and the kinds had
to be chosen by hand, and changing the file later meant doing it again preset by preset.

He wants it in one step: copy the file, paste it into Gitwall, and paste it again after an edit without getting
duplicates.

## Decision

**Settings › Presets › ⋯** offers *Copy as JSON* (the selected preset), *Copy All as JSON* and *Paste Presets…*. The
JSON goes through the clipboard. `PresetTransfer` in GitwallCore reads, writes and merges it; the app only moves the
text and shows the alerts.

### The format, version 1

```json
{
  "version": 1,
  "presets": [
    {
      "id": "6F0C2D6A-1B7E-4C55-9E0A-2D8E4B1F7A10",
      "name": "Waiting for me · agents",
      "query": "involves:franta-dxh (label:needs:approval OR (review-requested:@me -is:draft))",
      "icon": "hand.raised",
      "sort": "priority",
      "kinds": ["pullRequest", "issue"]
    }
  ]
}
```

| Key | Required | Value |
|---|---|---|
| `id` | yes | A UUID (`uuidgen`), any case. It is what makes a second paste replace instead of duplicate. |
| `name` | yes | Not blank. |
| `query` | yes | Gitwall's query syntax; it must parse. `""` means every item. |
| `icon` | no | An SF Symbol name; default `tray.full`. |
| `sort` | no | `lastActivity` (default), `newestCreated`, `oldestCreated` or `priority`. |
| `kinds` | no | A non-empty list of `pullRequest` and `issue`; default both. |

A bare list `[ … ]` is accepted as well, for a file that only ever holds presets. With the wrapper, `version` is
required and only `1` is read.

**A preset in the file is its query plus how it looks and sorts.** Accounts and repositories, the structured
filters (relation to me, drafts, review, checks, labels, authors, age, milestone, text), notifications and the menu
bar count are not in the format. The query already carries scope and conditions (`repo:`, `org:`, `assignee:`,
`label:` …), and the rest is a choice made on one Mac, not part of the view.

### Reading

Everything is checked before anything is written, so a paste either succeeds whole or changes nothing: the JSON,
the version, every key, the UUIDs, blank names, the query (with the same parser the editor uses), the sort, the kinds,
that the icon is an SF Symbol on this Mac, and duplicate ids inside the paste. **An unknown key anywhere is an
error**, not ignored: `sortBy` or `Icon` would otherwise vanish without a word and the preset would quietly look
different from the file. The alert names the preset by its position (from 1) and its name, and says what is wrong.

### Merging

- A preset whose `id` is already in Gitwall gets the pasted `name`, `icon`, `sort` and `kinds`, and its filter
  becomes the pasted query alone; the structured filters are cleared, because the file defines the preset only by
  its query. Its accounts and repositories, notifications and menu bar count stay as they were set in the app.
- A new `id` is appended at the end, with no account restriction, no notifications and no menu bar count.
- Presets that are not in the paste are left alone and keep their place. **Nothing is ever deleted.**
- Before writing, an alert says what will happen ("2 new, 1 replaced", plus the unchanged ones) and offers Cancel.
  A paste that changes nothing says so and writes nothing.

### Writing

The export writes every key of every preset, pretty-printed with sorted keys (the encoder of `SnapshotCoding`), kinds
in a fixed order, and `""` for a preset without a query. Pasting an export gives back exactly the same presets and
copying them again gives exactly the same text, so the file in the other repository diffs only where something
changed. When a copied preset has accounts, repositories or structured filters, the copy still happens and an alert
lists what was left out.

## Alternatives considered

- **Import from a file** (`NSOpenPanel`). The App Sandbox lets the app read only what it is entitled to; an open
  panel needs `com.apple.security.files.user-selected.read-only`, which Gitwall does not have, and reading the same
  file again later would need a security-scoped bookmark. It would also be a second step every time (find the file
  in the other repository) with the same format underneath. The clipboard is one step from an editor, a terminal
  (`pbcopy < presets.json`) or a chat with an agent, and needs no new entitlement.
- **A `gitwall://` deep link per preset.** One link per view, a URL-encoded query that nobody can read or review in
  a diff, and a URL handler that writes configuration on a click. Rejected.
- **Typing the query by hand.** Works today and stays possible; the name, icon, sort and kinds are still clicked,
  and nothing ties the preset in Gitwall to the one in the file, so the next edit starts over.
- **Matching by name instead of a stable id.** Renaming a preset in the file would add a second one. Rejected.
- **Carrying the structured filters, scopes and notifications too.** The format would mirror `config.json`, account
  UUIDs would not mean anything on another Mac, and the query already expresses the same conditions.
- **Ignoring unknown keys** for forward compatibility. A typo would be dropped silently; a new key comes with a new
  `version` instead.

## Consequences

- The format is a public contract, documented in the README under *Sharing presets*. Adding a key or changing a
  meaning needs `version: 2`; a build that reads version 1 refuses version 2 rather than guessing.
- Copy and paste round-trip exactly; `PresetTransferTests` hold that and every rule above.
- A preset pasted over one with structured filters loses them. The confirmation says so in general terms; the
  filters are not listed one by one.
- A pasted icon outside the editor's list is added to the editor's icon picker for that preset, so the preset can be
  edited without the icon disappearing.
- The query in the file is Gitwall's dialect of GitHub search: `priority:` and comma lists work in Gitwall, not on
  github.com (see ADR 0009 and [ADR 0012](0012-priority-comes-from-a-projects-field-then-labels.md)).
