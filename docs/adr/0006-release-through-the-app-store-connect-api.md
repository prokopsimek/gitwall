# 6. Release through the App Store Connect API

Date: 2026-09-10

## Context

Xcode on the release machine has no Apple ID signed in, so `xcodebuild -exportArchive` failed with
"No Accounts" and could not create the App Store profiles or the installer certificate. Filling in the store
listing by hand is also slow and easy to get wrong twice in a row.

## Decision

Use an App Store Connect API team key (Admin role) for everything that has an API: `xcodebuild
-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` registers identifiers, creates
profiles and uploads the build; `Scripts/asc.py` writes the metadata, uploads screenshots and submits for
review; `xcrun notarytool --key/--key-id/--issuer` notarizes. The key lives in
`~/.appstoreconnect/private_keys/` and is never committed.

## Consequences

- A release needs no signed-in Xcode and no app-specific password.
- Two things stay manual because Apple has no API for them: the App Privacy questionnaire and the Developer ID
  certificate (the API answers 403, "only the Account Holder"), which is created once in the developer portal.
- `Scripts/asc.py` is ours to maintain, including quirks such as re-committing a screenshot upload that stays
  in `UPLOAD_COMPLETE`.
