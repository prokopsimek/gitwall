#!/bin/zsh
# Regenerates every screenshot from the demo data: the App Store set (2880×1800 PNG, Scripts/out/wall) and the
# smaller copies the README and the website use (docs/screenshots/*.jpg). No real accounts are involved.
#
#   Scripts/make-screenshots.sh          (or: make screenshots)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DerivedData/Build/Products/Debug/Gitwall.app
OUT=Scripts/out
BIN="$APP/Contents/MacOS/Gitwall"

echo "==> Debug build"
xcodegen generate --spec project.yml --use-cache >/dev/null
xcodebuild -project Gitwall.xcodeproj -scheme Gitwall -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build >build/screenshots-build.log 2>&1 \
  || { grep -E "error:" build/screenshots-build.log | head; exit 1; }

# One demo run per capture set; each opens the main window, Settings › Presets and the popover.
capture() {
  local name=$1; shift
  rm -rf "$OUT/shots/$name"
  "$BIN" --debug-demo "$@" >/dev/null 2>&1 &
  local pid=$!
  swift Scripts/screenshots.swift waitfor "$pid" "Gitwall" "Gitwall Settings"
  sleep 3   # the popover opens a second after the windows, and SwiftUI needs a moment to lay out
  swift Scripts/screenshots.swift capture "$pid" "$OUT/shots/$name" >/dev/null
  kill "$pid" 2>/dev/null || true
  sleep 1
}

echo "==> Capture demo windows"
capture A --debug-demo-preset 2 --debug-demo-widgets   # All open, plus the four widget sizes
capture B --debug-demo-preset 1                        # Waiting for my review
capture C --debug-demo-preset 5                        # Open bugs (issues)
capture D --debug-demo-preset 6                        # Needs my attention (busy filter editor)

echo "==> Compose App Store set"
rm -rf "$OUT/wall"
for spec in Scripts/screenshot-specs/*.json; do
  swift Scripts/screenshots.swift compose "$spec" "$OUT/wall/$(basename "${spec%.json}").png" >/dev/null
done

echo "==> README copies"
mkdir -p docs/screenshots
for name in 01-hero 02-widgets 03-issues 04-filters 05-presets 07-menubar; do
  sips -Z 1600 -s format jpeg -s formatOptions 82 "$OUT/wall/$name.png" --out "docs/screenshots/$name.jpg" >/dev/null
done

# The Debug build must not keep the widget gallery or the URL scheme away from the installed app.
make --no-print-directory restore-registration

ls -la "$OUT/wall" docs/screenshots
