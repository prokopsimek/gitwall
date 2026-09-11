# Releasing Gitwall

Checklist for shipping a version to TestFlight, the Mac App Store and GitHub Releases.
Run every command from the repository root on a Mac with Xcode 26, XcodeGen and the
GitHub CLI, signed in to Xcode with the Apple account of team `ZHU9NYW7PP`.

## One-time setup

1. Certificates: Xcode > Settings > Accounts > Manage Certificates. You need
   "Apple Distribution" (App Store) and "Developer ID Application" (direct download).
   Automatic signing creates the Mac provisioning profiles, including the App Group.
2. Notarization credentials. Create an app-specific password at <https://appleid.apple.com>,
   then store it in the login keychain under the profile name used below:

   ```sh
   xcrun notarytool store-credentials "gitwall-notary" \
     --apple-id "<apple-id-email>" --team-id ZHU9NYW7PP
   ```

3. `gh auth status` must show you logged in with push access to `prokopsimek/gitwall`.
4. App Store Connect record "Gitwall" for bundle `cz.prokopsimek.gitwall` (see the
   metadata checklist at the end).

## 1. Bump the version

Edit `project.yml`:

- `MARKETING_VERSION`: the user-visible version, semver (for example `0.2.0`).
- `CURRENT_PROJECT_VERSION`: integer build number. Increase it for every upload;
  App Store Connect rejects a reused build number for the same marketing version.

Then regenerate and commit:

```sh
make generate
git commit -am "chore(release): v0.2.0"
```

Tag only after the build is verified (step 5).

## 2. Verify

```sh
make test
```

Optionally `make run` and check the popover, a widget of each size and a `gitwall://`
link by hand.

## 3. Archive

```sh
make archive
```

Produces `build/Gitwall.xcarchive` (Release, generic macOS destination, automatic signing).
Both exports below reuse this archive.

## 4. App Store Connect and TestFlight

```sh
xcodebuild -exportArchive \
  -archivePath build/Gitwall.xcarchive \
  -exportOptionsPlist Config/ExportOptions-appstore.plist \
  -exportPath build/export/appstore \
  -allowProvisioningUpdates
```

`Config/ExportOptions-appstore.plist` uses `method = app-store-connect` and
`destination = upload`, so the command re-signs with the Apple Distribution certificate
and uploads in one step. On CI without an Apple ID session, add an App Store Connect
API key: `-authenticationKeyPath <key.p8> -authenticationKeyID <id> -authenticationKeyIssuerID <issuer>`.

After the upload:

- Wait for processing (an email arrives, usually within 5 to 30 minutes).
- Export compliance is answered automatically: `Info.plist` carries
  `ITSAppUsesNonExemptEncryption = false` (set in `project.yml`) because the app uses
  only HTTPS.
- TestFlight for macOS: App Store Connect > TestFlight > macOS builds. Fill in
  "What to Test", add the build to an internal group. Testers install the
  TestFlight app for Mac (macOS 12 or later) and get the build there. External
  groups need a one-time Beta App Review.

## 4b. Metadata, screenshots and submission through the API

`Scripts/asc.py` talks to the App Store Connect API without extra dependencies. It reads
`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` (the `.p8` team key with the Admin role,
stored outside the repository, for example in `~/.appstoreconnect/private_keys/`). Never
commit the key or paste the IDs into tracked files.

```sh
Scripts/asc.py get "/v1/apps?filter[bundleId]=cz.prokopsimek.gitwall"          # app id
Scripts/asc.py get "/v1/apps/<app>/appStoreVersions"                            # version ids
Scripts/asc.py patch /v1/appStoreVersionLocalizations/<loc> '{"data": {...}}'   # texts from docs/appstore-listing.md
Scripts/asc.py upload-screenshots <loc> APP_DESKTOP Scripts/out/appstore/0*.png
Scripts/asc.py patch /v1/appStoreVersions/<version>/relationships/build '{"data": {"type": "builds", "id": "<build>"}}'
Scripts/asc.py post /v1/reviewSubmissions '{"data": {"type": "reviewSubmissions", "attributes": {"platform": "MAC_OS"}, "relationships": {"app": {"data": {"type": "apps", "id": "<app>"}}}}}'
```

Things the API needs that are easy to miss: the price schedule (`POST /v1/appPriceSchedules`
with the free price point of the base territory), availability (`POST /v2/appAvailabilities`
with every territory), the age rating declaration (all enums `NONE`, all booleans `false`,
only `ageRatingOverrideV2`, not the v1 field) and review details. App Privacy ("Data Not
Collected") has no public API and is published once in the web UI.

The same `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` flags make
`xcodebuild -exportArchive` register missing bundle IDs, create the App Store profiles and the
Mac Installer Distribution certificate, and upload the build without an Apple ID session in Xcode.

## 5. Developer ID build, notarization, GitHub Release

One-time: the Developer ID Application certificate. The App Store Connect API refuses to create it
("This operation can only be performed by the Account Holder"), so it is made once in the developer portal
from a certificate signing request:

```sh
openssl req -new -newkey rsa:2048 -nodes \
  -keyout ~/.appstoreconnect/private_keys/developer-id.key \
  -out ~/Desktop/Gitwall-DeveloperID.certSigningRequest \
  -subj "/CN=Prokop Simek/C=CZ"
```

Upload the request at <https://developer.apple.com/account/resources/certificates/add> (type
"Developer ID Application", profile type G2 Sub-CA), download the `.cer`, then import both halves so
`codesign` can use them:

```sh
security import ~/Downloads/developerID_application.cer -k ~/Library/Keychains/login.keychain-db
security import ~/.appstoreconnect/private_keys/developer-id.key -k ~/Library/Keychains/login.keychain-db \
  -T /usr/bin/codesign -T /usr/bin/productsign
security find-identity -v -p codesigning | grep "Developer ID"
```

Then every release is one command, which archives, exports with Developer ID, notarizes with the same API
key as the upload, staples, zips and publishes the GitHub Release:

```sh
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_<id>.p8
make release
```

What `make release` does, in case a step has to be repeated by hand:

```sh
xcodebuild -exportArchive -archivePath build/Gitwall.xcarchive \
  -exportOptionsPlist Config/ExportOptions-developer-id.plist \
  -exportPath build/export/developer-id -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
cd build/export/developer-id
ditto -c -k --keepParent Gitwall.app Gitwall-$VERSION.zip
xcrun notarytool submit Gitwall-$VERSION.zip --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple Gitwall.app
rm Gitwall-$VERSION.zip && ditto -c -k --keepParent Gitwall.app Gitwall-$VERSION.zip   # staple changed the bundle
shasum -a 256 Gitwall-$VERSION.zip > Gitwall-$VERSION.zip.sha256
spctl -a -vv -t exec Gitwall.app        # expect: accepted, source=Notarized Developer ID
```

If notarization comes back `Invalid`, read the log: `xcrun notarytool log <submission-id> --key ... --key-id ... --issuer ...`.

The direct-download build has no auto-update (see `docs/PLAN.md`); say so in the release notes and point to
the App Store for automatic updates.

## 6. Submit to the App Store

1. App Store Connect > App > the new version: attach the processed build.
2. Fill in "What's New".
3. Review notes: explain that Gitwall needs a GitHub or GitLab personal access token
   (read access to a public repository is enough), that it shows a menu bar item plus a
   main window and optional desktop widgets (right-click the desktop > Edit Widgets >
   Gitwall), and that the Dock icon can be switched off in Settings > General.
4. Submit for review.

## App Store Connect metadata checklist

- Name: `Gitwall`. Subtitle: `Pull requests and issues on your desktop`.
  Do not put "for Mac" or any Apple trademark in the name.
- Primary category: Developer Tools. Secondary: Productivity (optional).
- Privacy policy URL: <https://prokopsimek.github.io/gitwall/privacy/>
  (source: `docs/privacy.md`). The same link belongs in the app's About panel.
- Support URL: <https://github.com/prokopsimek/gitwall/issues>.
  Marketing URL: <https://prokopsimek.github.io/gitwall/>.
- App Privacy questionnaire: "Data Not Collected". This matches
  `Gitwall/Resources/PrivacyInfo.xcprivacy` and `GitwallWidget/PrivacyInfo.xcprivacy`.
- Age rating: 4+. Price: Free, all territories.
- Screenshots for Mac: PNG without alpha, 16:10, one of 1280×800, 1440×900, 2560×1600
  or 2880×1800 pixels. Generate them with the demo mode (see "Screenshots" below); the
  listing copy and the shot order live in `docs/appstore-listing.md`.
- Export compliance: HTTPS only, `ITSAppUsesNonExemptEncryption = false` is already in
  `Info.plist`; no documents to upload.
- Entitlements: only `app-sandbox`, `network.client` and `application-groups`. Check with
  `codesign -d --entitlements - build/export/appstore/Gitwall.app` before submitting.
- Description, keywords (pull request, merge request, GitHub, GitLab, code review, widget,
  menu bar), promotional text.

## Screenshots

Debug builds accept `--debug-demo`: the app starts with fictional accounts, presets and items
(`GitwallCore.DemoData`), keeps everything in memory (no App Group, no Keychain, no network) and
opens the main window, Settings › Presets and the menu bar popover at fixed sizes.
`--debug-demo-preset <index>` selects the preset shown in the main window and popover.
Run the binary directly so Launch Services keeps pointing at the installed app:

```sh
make build
APP=build/DerivedData/Build/Products/Debug/Gitwall.app
"$APP/Contents/MacOS/Gitwall" --debug-demo --debug-demo-preset 1 &
sleep 4
swift Scripts/screenshots.swift capture $! Scripts/out/shots      # one PNG per window, no shadow
kill $!
swift Scripts/screenshots.swift compose Scripts/out/shots/window-1-gitwall.png Scripts/out/appstore/01-main.png
make install   # make build re-pointed Launch Services at the Debug build
```

`compose` centers the capture on a 2880×1800 brand background and writes a PNG without alpha,
which is what App Store Connect accepts. Add `--debug-demo-widgets` to the demo launch and the
four widget sizes appear as transparent windows that `capture` saves like any other window.
The published set is defined by the JSON layouts in `Scripts/screenshot-specs/` (headline plus
hand-placed layers); regenerate it with:

```sh
for spec in Scripts/screenshot-specs/*.json; do
  swift Scripts/screenshots.swift compose "$spec" "Scripts/out/wall/$(basename "${spec%.json}").png"
done
```

The layouts expect captures in `Scripts/out/shots/w` (preset "All open" with widgets) and
`Scripts/out/shots/p1` (preset "Waiting for my review"); see `docs/appstore-listing.md` for the order.

## After the release

- Increase `CURRENT_PROJECT_VERSION` in `project.yml` right away so the next upload
  cannot collide.
- Once the App Store listing is live, replace the "coming soon" line in `docs/index.md`
  with the App Store link.
