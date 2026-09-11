# 2. Tokens in the classic Keychain, not the data-protection Keychain

Date: 2026-09-10

## Context

`KeychainTokenStore` originally used the data-protection Keychain (`kSecUseDataProtectionKeychain`), which is
the modern, iOS-like API. Every call failed with `errSecMissingEntitlement` (-34018) in development builds and
in `swift test`: that Keychain requires an application-identifier entitlement from a provisioning profile,
which plain test runners and locally signed builds do not have.

## Decision

Default to the classic macOS login Keychain, keyed by service `cz.prokopsimek.gitwall.tokens` and the account
UUID. `useDataProtectionKeychain: true` stays available for a future signed configuration.

## Consequences

- Tokens are readable by the app on the machine that stored them; the item ACL is bound to the code signature.
- Tests run against the real Keychain API without a profile.
- Items are not synced to iCloud and not migrated between Macs, which matches the product decision that
  Gitwall keeps everything local.
