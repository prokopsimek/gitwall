---
title: Privacy Policy
permalink: /privacy/
---

# Gitwall Privacy Policy

Effective date: 10 September 2026

Gitwall is a macOS menu bar app with desktop widgets that shows pull requests and issues from GitHub and GitLab. It is published by Prokop Simek as an individual. The source code is available under the MIT license at <https://github.com/prokopsimek/gitwall>.

## Summary

- Gitwall does not collect, store or transmit any personal data to the developer or to third parties.
- Gitwall contains no analytics, crash reporting, advertising or tracking code and uses no third-party services.
- All network requests go directly from your Mac to the GitHub or GitLab servers you configure.
- Access tokens are stored only in the macOS Keychain.

## What Gitwall accesses

To show your work items, Gitwall calls the GitHub and GitLab APIs on your behalf with the accounts you add in Settings. It reads only what those APIs return for the repositories you select: pull request and issue metadata (title, number, author, labels, review and CI status, timestamps), repository names and user avatars.

## Where data is stored

Everything Gitwall stores stays on your Mac.

| Data | Location | Purpose |
|---|---|---|
| Access tokens (personal access token or OAuth token) | macOS Keychain | Authenticating API calls |
| Accounts (without tokens), repository selection, views | App Group container, `config.json` | Configuration shared with the widget |
| Snapshot of pull request and issue metadata | App Group container, `snapshot.json` and `snapshot.previous.json` | Widget display, offline display, detecting changes for notifications |
| Avatar images | App Group container, `avatars/` | Row icons in the popover and widget |
| Preferences such as the refresh interval | `UserDefaults` | App settings |

The App Group container is `~/Library/Group Containers/ZHU9NYW7PP.cz.prokopsimek.gitwall/`. Gitwall does not sync any of this to iCloud or to any other service.

## Network connections

Gitwall connects only to:

- the GitHub or GitLab instances you configure (for example `api.github.com`, `gitlab.com` or a self-hosted server), and
- the avatar URLs those APIs return.

All connections use HTTPS. Gitwall has no server of its own and the developer receives no data from the app.

## Notifications

If you enable notifications, Gitwall shows local macOS notifications about changes in your views (new items, review requests, approvals, CI failures). No push notification service is involved.

## Deleting your data

- Remove an account in Settings to delete its token from the Keychain and its items from the local snapshot.
- Delete the app to stop all processing. To remove the cached data as well, delete the folder `~/Library/Group Containers/ZHU9NYW7PP.cz.prokopsimek.gitwall`. Any remaining Keychain items can be found in Keychain Access by searching for "gitwall".
- Revoke the token on GitHub or GitLab to invalidate it at the source.

## Changes to this policy

Changes are published at this address. The full history is in the repository.

## Contact

Questions about privacy: open an issue at <https://github.com/prokopsimek/gitwall/issues>.
