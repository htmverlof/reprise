#!/bin/bash
# Builds Reprise and installs it into /Applications, signed with the persistent
# local "Encore Local Signing" certificate (created 26-09-2026 in the login
# keychain, kept under its original name — it's an internal signing identity,
# never user-visible, so renaming it would just mean redoing the one-time
# keychain trust step for no real benefit) instead of an ad-hoc signature.
# Ad-hoc signing hashes the binary's own content, so it changes on every
# rebuild — macOS then treats each build as a different app and resets Full
# Disk Access / Files and Folders grants. This certificate has a stable
# identity (tied to its key, not the binary), so permission grants survive
# rebuilds as long as this same identity keeps getting used. Falls back to
# ad-hoc signing automatically on a machine that doesn't have this identity
# yet — see the fallback below and the README.
#
# Also (re)creates Info.plist and the icon inside the bundle from Resources/
# every run, not just the executable — so the whole bundle is reproducible
# from source, not dependent on whatever happened to already exist on disk.
set -e
cd "$(dirname "$0")"

IDENTITY="Encore Local Signing"
APP="/Applications/Reprise.app"
EXECUTABLE_NAME="Reprise"

swift build -c release

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -f "$APP/Contents/MacOS/$EXECUTABLE_NAME" ]; then
    TS=$(date +%Y%m%d-%H%M%S)
    cp "$APP/Contents/MacOS/$EXECUTABLE_NAME" "$APP/Contents/MacOS/$EXECUTABLE_NAME.backup-$TS"
fi
cp .build/release/Reprise "$APP/Contents/MacOS/$EXECUTABLE_NAME"

# Falls back to ad-hoc signing on a machine that doesn't have this identity yet (e.g. a
# fresh clone on another Mac) instead of hard-failing — codesign errors out entirely if
# asked to sign with a name it can't find in any keychain. Ad-hoc still works, it just
# means Full Disk Access needs re-granting after every rebuild until a persistent local
# identity is set up there too (see README: "Keeping Full Disk Access across rebuilds").
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep -s "$IDENTITY" "$APP"
    echo "Installed and restarted Reprise, signed with '$IDENTITY'."
else
    codesign --force --deep -s - "$APP"
    echo "Installed and restarted Reprise with an ad-hoc signature (no '$IDENTITY' identity"
    echo "found in this Mac's keychain). This works, but macOS will ask you to re-grant Full"
    echo "Disk Access after every rebuild until you set up a persistent signing identity —"
    echo "see the README section \"Keeping Full Disk Access across rebuilds\"."
fi

pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
sleep 2
open -a "$APP"
