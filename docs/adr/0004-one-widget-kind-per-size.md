# 4. One widget kind per size

Date: 2026-09-10

## Context

Gitwall started with a single widget kind offering all four families. The gallery then showed the same name
and description for every size, and the user could not tell what they were dragging. Renaming the kind to fix
this broke every placed widget: WidgetKit fails a widget whose kind disappeared with error 1100, and chronod
then backs off for roughly a day before asking again. Switching a placed static widget to a configurable one
under the same kind fails with error 1103.

## Decision

Four kinds, one per size: `cz.prokopsimek.gitwall.counter`, `.list`, `.board`, `.wideboard`. They are
constants in `GitwallCore.AppGroup.widgetKinds` and are never renamed. An app test asserts their values.

## Consequences

- Each gallery entry has its own name, description and preview, so the size is obvious before dropping it.
- The four `Widget` types share one view and one timeline provider through `PresetWidgetSpec`.
- The kinds are now part of the app's public contract with the user's desktop; a rename would silently break
  placed widgets, so it must never happen.
