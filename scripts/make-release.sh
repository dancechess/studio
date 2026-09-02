#!/usr/bin/env bash
# Packages "dist/DC Studio.app" into the DMG we ship on GitHub Releases.
# Both a local run and .github/workflows/release.yml go through here, so what
# CI publishes is what you can reproduce on your own machine.
#
#   VERSION=0.2.0 ./scripts/make-release.sh
#
# The bundle is ad-hoc signed (see make-app.sh) — not notarized — so the DMG
# needs the quarantine dance documented in the README. Once a Developer ID is
# available, sign in make-app.sh and staple here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
NAME="DC-Studio-$VERSION-arm64"
APP="$ROOT/dist/DC Studio.app"
DMG="$ROOT/dist/$NAME.dmg"
STAGE="$ROOT/dist/dmg-stage"

VERSION="$VERSION" "$ROOT/scripts/make-app.sh"

# staging tree = the app next to an /Applications drop target, the gesture
# every Mac user already knows
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -srcfolder "$STAGE" -volname "DC Studio $VERSION" \
    -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"

(cd "$ROOT/dist" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")

echo "built:  $DMG  ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
