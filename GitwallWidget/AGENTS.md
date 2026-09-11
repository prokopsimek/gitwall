# Widget extension

Four widgets, one per size, sharing `GitwallWidgetView`. Each reads `config.json` and `snapshot.json` from the
App Group and applies the preset chosen for that widget instance. It never touches the network or the Keychain.

- `GitwallWidgetBundle.swift` – the four `Widget` types.
- `GitwallWidget.swift` – timeline provider, `PresetWidgetSpec` (kind, name, description per size).
- `WidgetViews.swift` – the views and `PresetEntry`. **Also compiled into the app target** so `--debug-demo-widgets`
  can render the same views into windows for screenshots (see `project.yml`).
- `PresetIntent.swift` – `SelectPresetIntent`, `PresetEntity`, `PresetQuery`.

## Traps, learned the hard way

- **Never rename a widget `kind`** (`AppGroup.widgetKinds`). Placed widgets are bound to it; a kind that
  disappears fails with error 1100 and chronod then backs off for a day. A static widget also cannot become a
  configurable one in place (error 1103). One kind per size keeps the gallery names meaningful.
- Only one copy of the app may be registered with Launch Services. `make run` and `make install` unregister
  the other copy; `make archive` and `make release` drop their archive and export copies and point Launch
  Services back at the installed app (`make restore-registration`). A stale copy makes the widget silently
  vanish from the gallery.
- After a widget change the gallery may show stale or no Gitwall entries until the user opens
  "Edit Widgets…", which triggers a fresh descriptor fetch. `make register` restarts chronod.
- The extension carries its own `AppIcon` asset; without it the gallery row has no icon.
