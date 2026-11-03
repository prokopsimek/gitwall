# 14. Walls travel with presets in one file

Date: 2026-11-03

## Context

Gitwall shows one preset at a time: in the popover, in the main window and in each desktop widget. Prokop wants
several presets side by side in the app, in a window on the laptop and full screen on a second monitor, as tiles the
size of the desktop widgets, grouped into tabs. That is a *Wall*: a named set of *Tiles*, each showing one preset at
one *Tile size* (see the [glossary](../../GLOSSARY.md)).

Walls are set up the way presets are since [ADR 0013](0013-presets-travel-as-json-with-stable-ids.md): kept as JSON in
another repository, next to the agents they watch, and pasted into Gitwall in one step. The preset file is a public
contract, and ADR 0013 says a new key or a changed meaning needs a new version.

## Decision

### One file, version 2

A Gitwall file carries presets and walls together:

```json
{
  "version": 2,
  "presets": [
    { "id": "6F0C2D6A-1B7E-4C55-9E0A-2D8E4B1F7A10", "name": "Waiting for me · agents", "query": "involves:franta-dxh" }
  ],
  "walls": [
    {
      "id": "3C1F6A70-5D2B-4E8A-9B47-0F2C6D8E1A35",
      "name": "Waiting for me",
      "tiles": [
        { "preset": "6F0C2D6A-1B7E-4C55-9E0A-2D8E4B1F7A10", "size": "large" }
      ]
    }
  ]
}
```

| Key | Required | Value |
|---|---|---|
| `version` | yes | `2`. |
| `presets` | no | Presets exactly as in version 1. |
| `walls` | no | At least one of `presets` and `walls` holds something. |
| wall `id` | yes | A UUID. A second paste replaces the wall with that id instead of adding another. |
| wall `name` | yes | Not blank. |
| wall `tiles` | no | Default none. |
| tile `preset` | yes | The id of a preset in the same file or already in Gitwall. |
| tile `size` | no | `small`, `medium` (default), `large` or `extraLarge`: 1, 3, 7 or 14 rows, like the widgets. |

Version 1 stays exactly as it was: a file with `"version": 1` or a bare list of presets is handed to the version 1
reader unchanged, and *Copy as JSON* of presets alone still writes version 1. A version 1 file with `walls` is refused
with a pointer to version 2 rather than read half.

**Edit › Paste Configuration…** (⇧⌘V), **Settings › Presets › ⋯ › Paste Presets…** and the empty Walls window all take
the whole file. **Copy Wall as JSON** writes version 2 with the wall and every preset its tiles show, in the app's
order, so the text pastes into another installation as it is.

### Reading and merging

The rules of ADR 0013 carry over: everything is checked before anything is written, unknown keys are errors, ids must
be UUIDs and appear once, names must not be blank, sizes must be known, and every tile's preset must exist in the file
or in the app. An error names the wall or preset by its position and name, and the tile by its position.

Presets merge first, by the rules of ADR 0013. Then walls: a wall whose id Gitwall already has is replaced whole, name
and tiles, in its place; a new id is appended; walls that are not in the file stay as they are. **Nothing is ever
deleted.** The confirmation says what will happen ("2 new walls, 10 presets replaced") and a paste that changes
nothing writes nothing.

### A tile points at a preset

A tile names a preset by id and adds only its size. Editing the preset changes every wall that shows it, the widgets
and the walls agree on what a preset means, and the query is written once. When the preset is deleted, the tile stays
and says *Preset deleted* with a Remove button; nothing disappears from a wall by itself.

### What stays on this Mac

Tile ids, the selected wall, zoom and rotation are not in the file. Tile ids only tell the tiles of one wall apart in
the app. Zoom and rotation depend on the monitor and on how the wall is used (a laptop window or an unattended screen
across the room), so they live in the app's preferences, like the window frame.

## Alternatives considered

- **A separate walls file next to the preset file.** Two pastes for one setup, and a walls file whose tiles point at
  presets that are not there yet fails on its own. One file pastes in one step and checks its own references.
- **Keeping version 1 and adding `walls` to it.** ADR 0013 promises that a version never changes meaning; a build
  that only knows version 1 would refuse the key with a message about presets. Version 2 is refused cleanly by such a
  build instead.
- **A query per tile instead of a preset.** Every tile would repeat its query, the widgets and the walls could
  disagree about the same view, and a change would have to be made in several places. A tile that needs a view of its
  own gets a preset.
- **Deleting tiles together with their preset.** Silent, and a preset pasted back a minute later would come back to
  an emptier wall. The placeholder keeps the gap visible until someone decides.
- **Zoom and rotation in the file.** They are choices of one screen; carrying them would make a laptop paste a
  setting meant for a wall monitor.

## Consequences

- The Gitwall file is a public contract, documented in the README under *Sharing presets*. A new key or a
  changed meaning needs version 3; a build that reads versions 1 and 2 refuses version 3.
- Writing and reading again round-trip exactly; `GitwallFileTests` hold that and every rule above, `PresetTransferTests`
  still hold version 1.
- `config.json` gains `walls`, read with `decodeIfPresent`, so a configuration written before walls keeps loading.
- The tiles of the Walls window and the desktop widgets are drawn by the same `TileView` (GitwallUI); the widgets
  render pixel-identical to before the move.
