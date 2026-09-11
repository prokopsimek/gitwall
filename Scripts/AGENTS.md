# Scripts

Tooling for releases and assets. Nothing here ships inside the app.

| Script | Purpose |
|---|---|
| `asc.py` | App Store Connect API client with no third-party dependencies: ES256 JWT signed through `openssl`, `get/post/patch/delete`, and chunked screenshot upload. |
| `screenshots.swift` | `waitfor <pid> <titles…>` blocks until the demo's windows exist; `capture <pid> <dir>` saves every window of a running process (also on other Spaces); `compose <spec.json|window.png> <out.png>` puts them on the 2880×1800 brand background without alpha. |
| `make-screenshots.sh` | The whole screenshot pipeline behind `make screenshots`. |
| `screenshot-specs/*.json` | The published App Store screenshot layouts: headline, subtitle and hand-placed layers with optional crops. |
| `make-icon.swift`, `icon-variants.swift` | App icon rendering (concept F: brick wall, teal pull-request glyph). |

## Credentials

`asc.py` reads `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` from the environment. The `.p8` key lives in
`~/.appstoreconnect/private_keys/` and never in the repository, not even in an example. The same key works for
`xcodebuild -authenticationKey*` and `xcrun notarytool --key`.

## Screenshots

`make screenshots` (runs `make-screenshots.sh`) does everything from the demo data: Debug build, four demo runs
(one per preset the layouts need), `waitfor` + `capture`, `compose` of every layout in `screenshot-specs/`
into `out/wall/` (App Store, 2880×1800 PNG), and 1600 px JPEG copies into `docs/screenshots/` for the README and
the website. It ends with `make restore-registration`, so the Debug build does not steal the widget gallery.
