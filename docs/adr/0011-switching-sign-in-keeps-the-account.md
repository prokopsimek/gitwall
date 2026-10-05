# 11. Switching how an account signs in keeps the account

Date: 2026-10-05

## Context

Reported on 2026-10-04: a GitHub account connected by a personal access token was removed and GitHub was signed
in to instead. Afterwards every preset over GitHub showed nothing, although more than thirty pull requests were
waiting for review.

Nothing was broken in the sign-in. Watched repositories (`Account.sources`), presets (`PresetScope.accountID`)
and widgets all hang on the account record and its id. Add Account always made a new record with a new id and
no sources, and removing the old one took its sources and its presets with it. An account without sources sends
no request at all (`GitHubProvider.fetchItems` builds its queries from `sources`), the sync reports `ok`, and
the empty state said "Nothing here", because "No repositories selected" was shown only when *no* account had
any, and the GitLab account did.

The one path that keeps the id, `AppEnvironment.replaceCredential`, was reachable only as "Replace Token…" on a
token account and "Sign in again…" on a signed-in one, so there was no way to move an account from one to the
other.

## Decision

**An account is the same account when the provider, the server and the login match**, whatever the way it signs
in (`AppConfig.replaceableAccount(kind:baseURL:login:)`). Hosts and logins are compared without case; the port
and a path prefix belong to the server.

- Add Account verifies the credential and, when exactly one such account exists, asks before it stores anything:
  **Replace Sign-In** keeps the record with its repositories, presets and widgets; **Add as Separate Account**
  does what Add Account always did.
- The account menu offers the other way to sign in on the same record: "Sign in with GitHub…" or
  "Sign in with GitLab…" on a token account (where Gitwall has a built-in client for the host), and
  "Use a Token Instead…" on a signed-in one.
- **Several matching accounts are left alone.** One fine-grained token per organization means the same login
  several times on purpose, and there is no single record a new credential obviously belongs to, so nothing is
  offered and the new account is added as before.
- Nothing is merged or migrated automatically. Removing an account still removes its sources and presets; the
  point is that switching no longer needs a removal.

**An account that watches nothing is named wherever its absence shows** (`AppConfig.emptiness(of:)`,
`AppConfig.idleAccounts(visibleTo:)`): in Settings › Accounts, in the empty state of a preset that looks at it,
and in the preset editor, each with a way to Settings › Repositories for that account.

## Consequences

- A second record for the same person is now a deliberate choice, made on a screen that says what it costs.
- `replaceCredential` takes the new owner from the credential, as before. Replacing with a credential of a
  different person is not prevented; Add Account never offers it, because it only offers the matching account.
- The identity rule lives in GitwallCore and is covered by `AccountIdentityTests`; the app-level flow by
  `GitwallTests/AccountSwitchTests`. A new place that lists items needs the idle-account hint too.
- Settings › Repositories keeps its list per account (`RepositoryPicker.shouldLoad`), because the tab outlives a
  change of account and used to show the previous account's repositories for the next one.
