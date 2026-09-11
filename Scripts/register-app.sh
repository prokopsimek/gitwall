#!/bin/sh
# Point Launch Services and the widget service at exactly one copy of Gitwall.app.
#
# Duplicate bundles are not cosmetic. WidgetKit binds a placed widget to the bundle identifier, so with two
# copies registered the desktop widget can be served by one of them while "Edit Widget" stores the chosen
# preset against the other: the widget keeps rendering the first preset and the choice looks ignored. Xcode
# registers every archive, export and DerivedData copy on its own, and a downloaded release usually lands in
# /Applications next to whatever `make install` put in ~/Applications, so copies pile up quickly.
#
# Usage: Scripts/register-app.sh <app-to-keep>

set -eu

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
keep=${1:?usage: register-app.sh <app-to-keep>}
[ -d "$keep" ] || { echo "register-app: $keep does not exist" >&2; exit 1; }
# Launch Services stores resolved paths; compare against one too, or the copy to keep is unregistered as well.
keep=$(cd "$keep" && pwd -P)

registered=$("$LSREGISTER" -dump 2>/dev/null |
    sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*\/Gitwall\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u)

others=$(printf '%s\n' "$registered" | grep -v "^$keep\$" || true)
if [ -n "$others" ]; then
    printf '%s\n' "$others" | while read -r app; do
        [ -n "$app" ] || continue
        "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
        echo "register-app: unregistered $app"
    done
fi

"$LSREGISTER" -f "$keep" >/dev/null 2>&1 || true
# Registering the app does not always re-announce its extension; do it explicitly so the gallery sees it.
pluginkit -a "$keep/Contents/PlugIns/GitwallWidget.appex" >/dev/null 2>&1 || true
pkill -f GitwallWidget.appex >/dev/null 2>&1 || true
killall chronod >/dev/null 2>&1 || true
echo "register-app: the app and the widget now come from $keep"
