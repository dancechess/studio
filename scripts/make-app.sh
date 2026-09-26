#!/usr/bin/env bash
# Assembles "dist/DC Studio.app" from the SPM release build — no Xcode needed.
#
# Signing: a Developer ID identity in the keychain is picked up automatically
# and brings the hardened runtime and a secure timestamp with it, which is
# what notarization requires. With no such identity the build falls back to
# an ad-hoc signature — fine to run on this machine, refused by Gatekeeper
# anywhere else. SIGN_ID overrides the choice; SIGN_ID=- forces ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/DC Studio.app"
# The release workflow passes VERSION from the tag. A local build falls
# back to the newest tag rather than a number written here, which went
# stale: 0.3.0 built on this machine called itself 0.2.0 in Finder.
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0-dev}"

"$ROOT/scripts/build-core.sh" >/dev/null
(cd "$ROOT/app" && swift build -c release)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/StudioApp" "$APP/Contents/MacOS/DCStudio"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DC Studio</string>
    <key>CFBundleDisplayName</key><string>DC Studio</string>
    <key>CFBundleIdentifier</key><string>com.dancechess.DCStudio</string>
    <key>CFBundleExecutable</key><string>DCStudio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.board-games</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PGN Chess Games</string>
            <key>CFBundleTypeExtensions</key><array><string>pgn</string></array>
            <key>CFBundleTypeRole</key><string>Editor</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# SPM resource bundle (piece images): Bundle.module looks for it inside
# Contents/Resources of the enclosing app
cp -R "$ROOT/app/.build/release/DanceChessStudio_StudioApp.bundle" "$APP/Contents/Resources/"

cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# bundled engine: the analysis panel probes Contents/Resources first
# (the sandboxed app can't read /opt/homebrew); GPL binary, ships as-is
STOCKFISH="$(command -v stockfish || true)"
if [ -n "$STOCKFISH" ]; then
    cp "$STOCKFISH" "$APP/Contents/Resources/stockfish"
else
    echo "warn: no stockfish on PATH — engine panel will need a brew install"
fi

# --- signing ---------------------------------------------------------------
# Inside out: every nested executable first, the app last. Signing the outer
# bundle seals what is inside it, so a later signature on an inner binary
# invalidates the outer one.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"

if [ "$SIGN_ID" = "-" ]; then
    OPTS=()
    echo "signing: ad-hoc (no Developer ID identity found)"
else
    # --options runtime is the hardened runtime, and --timestamp asks Apple's
    # timestamp server for a countersignature. Notarization rejects a build
    # missing either, and a timestamp is what keeps already-shipped copies
    # valid after the certificate itself expires.
    OPTS=(--options runtime --timestamp)
    echo "signing: $SIGN_ID"
fi

sign() { codesign --force --sign "$SIGN_ID" "${OPTS[@]+"${OPTS[@]}"}" "$@"; }

if [ -f "$APP/Contents/Resources/stockfish" ]; then
    sign "$APP/Contents/Resources/stockfish"
fi
# Nothing else to sign: the only Mach-O files in the bundle are the main
# executable and stockfish. SPM's resource bundle is a flat directory of
# images with no Info.plist, which codesign refuses outright ("bundle format
# unrecognized") and which needs no signature — signing the app seals it into
# CodeResources like any other resource.
sign "$APP"

codesign --verify --strict --deep "$APP"
echo "built: $APP"
