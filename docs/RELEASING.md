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

## 5. Developer ID build, notarization, GitHub Release

Export the same archive signed with Developer ID:

```sh
xcodebuild -exportArchive \
  -archivePath build/Gitwall.xcarchive \
  -exportOptionsPlist Config/ExportOptions-developer-id.plist \
  -exportPath build/export/developer-id \
  -allowProvisioningUpdates
```

Notarize, staple and zip:

```sh
VERSION=$(grep MARKETING_VERSION project.yml | awk '{print $2}')
cd build/export/developer-id
ditto -c -k --keepParent Gitwall.app Gitwall-$VERSION.zip
xcrun notarytool submit Gitwall-$VERSION.zip --keychain-profile "gitwall-notary" --wait
xcrun stapler staple Gitwall.app
# Stapling modifies the bundle, so build the final zip only now.
rm Gitwall-$VERSION.zip
ditto -c -k --keepParent Gitwall.app Gitwall-$VERSION.zip
xcrun stapler validate Gitwall.app
spctl -a -vv -t exec Gitwall.app          # expect: accepted, source=Notarized Developer ID
shasum -a 256 Gitwall-$VERSION.zip > Gitwall-$VERSION.zip.sha256
cd -
```

If `notarytool` reports `Invalid`, read the log:

```sh
xcrun notarytool log <submission-id> --keychain-profile "gitwall-notary"
```

Tag and publish the release:

```sh
git tag -a v$VERSION -m "Gitwall $VERSION"
git push origin v$VERSION
gh release create v$VERSION \
  build/export/developer-id/Gitwall-$VERSION.zip \
  build/export/developer-id/Gitwall-$VERSION.zip.sha256 \
  --title "Gitwall $VERSION" --generate-notes
```

The direct-download build has no auto-update (see `docs/PLAN.md`); say so in the release
notes and point to the App Store for automatic updates.

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
which is what App Store Connect accepts. Repeat with other presets and windows; the required
set is listed in `docs/appstore-listing.md`.

## After the release

- Increase `CURRENT_PROJECT_VERSION` in `project.yml` right away so the next upload
  cannot collide.
- Once the App Store listing is live, replace the "coming soon" line in `docs/index.md`
  with the App Store link.
