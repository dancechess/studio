#!/usr/bin/env bash
# Packages "dist/DC Studio.app" into the DMG we ship on GitHub Releases.
# Both a local run and .github/workflows/release.yml go through here, so what
# CI publishes is what you can reproduce on your own machine.
#
#   VERSION=0.2.0 ./scripts/make-release.sh
#
# When make-app.sh found a Developer ID, the DMG is signed, sent to Apple for
# notarization and stapled, so a download opens with no Gatekeeper detour.
# Credentials come from a notarytool keychain profile (NOTARY_PROFILE, default
# "dcstudio") or, in CI, from NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER. With
# neither, the DMG ships unnotarized and the README's quarantine steps apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The release workflow passes VERSION from the tag. A local build falls
# back to the newest tag rather than a number written here, which went
# stale: 0.3.0 built on this machine called itself 0.2.0 in Finder.
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0-dev}"
NAME="DC-Studio-$VERSION-arm64"
APP="$ROOT/dist/DC Studio.app"
DMG="$ROOT/dist/$NAME.dmg"
STAGE="$ROOT/dist/dmg-stage"

VERSION="$VERSION" "$ROOT/scripts/make-app.sh"

# --- who is signing, and can we notarize ----------------------------------
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
NOTARY_PROFILE="${NOTARY_PROFILE:-dcstudio}"

notary_args=()
if [ -n "${NOTARY_KEY:-}" ]; then
    notary_args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
fi

NOTARIZE=no
if [ -n "${SIGN_ID:-}" ] && [ "$SIGN_ID" != "-" ] && [ ${#notary_args[@]} -gt 0 ]; then
    NOTARIZE=yes
fi

# --- pass one: the app ----------------------------------------------------
# Two rounds, because a ticket stapled to the disk image covers the image and
# not what comes out of it. An app carrying its own ticket opens on a Mac
# that is offline, or one the file reached by AirDrop rather than download.
if [ "$NOTARIZE" = yes ]; then
    ZIP="$ROOT/dist/notarize-app.zip"
    rm -f "$ZIP"
    # ditto, not zip: it preserves the symlinks and extended attributes the
    # signature is computed over
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "notarizing the app — a few minutes"
    xcrun notarytool submit "$ZIP" "${notary_args[@]}" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

# staging tree = the app next to an /Applications drop target, the gesture
# every Mac user already knows
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -srcfolder "$STAGE" -volname "DC Studio $VERSION" \
    -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"

# --- pass two: the disk image ---------------------------------------------
if [ "$NOTARIZE" = yes ]; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
    echo "notarizing the disk image — a few minutes"
    xcrun notarytool submit "$DMG" "${notary_args[@]}" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "not notarized: no Developer ID identity and/or no notary credentials"
    echo "  (the README's quarantine steps apply to this build)"
fi

(cd "$ROOT/dist" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")

echo "built:  $DMG  ($(ls -lh "$DMG" | awk '{print $5}'))"
cat "$DMG.sha256"
