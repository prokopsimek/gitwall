# 5. OAuth sign-in with silent refresh

Date: 2026-09-11

## Context

Personal access tokens work but ask the user to visit a settings page, pick scopes and paste a string. The
product requirement is stronger than convenience: the user signs in once and is never asked again, so expiring
access tokens must be invisible. GitHub and GitLab need different flows. A desktop app cannot keep a client
secret, so both must be public clients.

## Decision

- GitHub.com and GitHub Enterprise Server: OAuth device flow. Gitwall's OAuth App has token expiration off,
  so the token never expires and there is nothing to refresh.
- GitLab.com and self-managed GitLab: authorization code with PKCE (S256) through
  `ASWebAuthenticationSession`, redirect `gitwall://oauth/gitlab`. Access tokens live two hours and refresh
  tokens rotate on use.
- `TokenRefresher` (an actor in GitwallAuth) refreshes proactively inside a ten-minute leeway and reactively
  after a 401, with a single in-flight refresh per account and one atomic Keychain write of the rotated pair.
- `TokenReading` gained `tokenAfterUnauthorized`, so `SyncEngine` retries a rejected fetch exactly once.
- `invalid_grant` marks the account as needing a new sign-in and stops retrying until a different credential
  is stored; transient failures keep the current token and try again on the next sync.
- Self-hosted instances keep the personal access token as the default and accept a client ID the user
  registered on their own server.

## Consequences

- Client IDs are public identifiers of public clients and live in `OAuthClients.swift`; there is no secret
  to protect anywhere in the repository or on disk.
- Losing the rotated refresh token would log the user out, which is why the write is a single `set` and why
  concurrent syncs share one refresh.
- The last snapshot stays visible when an account needs re-authentication, so a revoked token degrades to a
  quiet "Sign in again" instead of an empty widget.
