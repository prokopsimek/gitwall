# 1. Team-ID style App Group identifier

Date: 2026-09-10

## Context

The app and the widget share `config.json`, `snapshot.json` and cached avatars through an App Group. Apple
recommends the iOS-style `group.` prefix for new macOS code, and the original plan used
`group.cz.prokopsimek.gitwall`. With automatic signing and no explicit provisioning profile downloaded, writes
into that container were denied at runtime: the container URL resolved, but the sandbox refused the write.

## Decision

Use the Team-ID style identifier `ZHU9NYW7PP.cz.prokopsimek.gitwall` for the App Group in both targets.

## Consequences

- Works with automatic signing without downloading an explicit profile, which keeps `make build` a one-step
  command on a fresh machine.
- The identifier is duplicated in `project.yml` (two entitlements blocks) and in `GitwallCore.AppGroup`;
  the app test asserts they match.
- Changing it later orphans every user's snapshot and configuration, so it is effectively permanent.
