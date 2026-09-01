#!/usr/bin/env bash
# Assembles dist/MacBase.app from the SPM release build — no Xcode needed.
# Ad-hoc signed; for public distribution re-sign with a Developer ID and
# notarize (xcrun notarytool, present in the Command Line Tools).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/MacBase.app"
VERSION="0.1.0"

"$ROOT/scripts/build-core.sh" >/dev/null
(cd "$ROOT/app" && swift build -c release)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/MacBaseApp" "$APP/Contents/MacOS/MacBase"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacBase</string>
    <key>CFBundleDisplayName</key><string>MacBase</string>
    <key>CFBundleIdentifier</key><string>com.dancechess.MacBase</string>
    <key>CFBundleExecutable</key><string>MacBase</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.board-games</string>
</dict>
</plist>
PLIST

# SPM resource bundle (piece images): Bundle.module looks for it inside
# Contents/Resources of the enclosing app
cp -R "$ROOT/app/.build/release/MacBaseDev_MacBaseApp.bundle" "$APP/Contents/Resources/"

# bundled engine: the analysis panel probes Contents/Resources first
# (the sandboxed app can't read /opt/homebrew); GPL binary, ships as-is
STOCKFISH="$(command -v stockfish || true)"
if [ -n "$STOCKFISH" ]; then
    cp "$STOCKFISH" "$APP/Contents/Resources/stockfish"
    codesign --force --sign - "$APP/Contents/Resources/stockfish"
else
    echo "warn: no stockfish on PATH — engine panel will need a brew install"
fi

codesign --force --sign - "$APP"
echo "built: $APP"
