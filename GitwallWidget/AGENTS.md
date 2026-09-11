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
- Only one copy of the app may be registered with Launch Services, and `Scripts/register-app.sh` (behind
  `make register` / `make restore-registration`) enforces it by unregistering every other copy it finds in
  `lsregister -dump`. Two copies of the same bundle identifier — say a downloaded release in `/Applications`
  next to what `make install` put in `~/Applications` — are worse than cosmetic: the desktop widget can be
  served by one of them while "Edit Widget" stores the chosen preset against the other, so the widget keeps
  rendering the first preset and the choice looks ignored. A stale copy also makes the widget vanish from the
  gallery. `pgrep -lf GitwallWidget.appex` says which copy is really serving the widget.
- After a widget change the gallery may show stale or no Gitwall entries until the user opens
  "Edit Widgets…", which triggers a fresh descriptor fetch. `make register` restarts chronod.
- The extension carries its own `AppIcon` asset; without it the gallery row has no icon.
