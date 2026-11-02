# Glossary

Domain terms as Gitwall uses them. How they are implemented lives in the code and in [docs/adr](docs/adr).

- **Preset** – a named view of pull requests and issues: a query, a sort order and an icon, optionally narrowed to
  some accounts and repositories. The popover, the main window and every widget show one preset at a time. The
  interface may call it a *view*.
- **Preset file** – portable JSON holding presets, each with a stable id, so the same presets can be kept outside
  Gitwall and pasted in again after a change without being duplicated. See
  [ADR 0013](docs/adr/0013-presets-travel-as-json-with-stable-ids.md) and *Sharing presets* in the README.
- **Priority** – how urgent an item is, P0 (most urgent) to P3. It comes from the *Priority* field of a GitHub project
  the item is in, otherwise from a `p0`–`p3` label. See
  [ADR 0012](docs/adr/0012-priority-comes-from-a-projects-field-then-labels.md).
- **Query** – the conditions of a preset, written in GitHub's search syntax and checked by Gitwall against the items
  it already has, never sent to GitHub or GitLab. See
  [ADR 0008](docs/adr/0008-preset-queries-use-github-search-syntax-locally.md) and
  [ADR 0009](docs/adr/0009-preset-queries-accept-and-or-and-parentheses.md).
