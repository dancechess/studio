#!/usr/bin/env bash
# Cuts a public release from this machine.
#
#   git tag -a v0.3.1 -F notes.md && ./scripts/publish-release.sh v0.3.1
#
# Releases are built here rather than on a runner because the signing key
# stays in this Mac's keychain and never reaches GitHub. What that buys in
# safety it costs in ceremony, so this script does the ceremony: it refuses
# to publish anything that is not signed, notarized and stapled, which is the
# one mistake that would quietly put the old Gatekeeper warning back in front
# of every download while the README promises it is gone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>   (e.g. v0.3.1)"; exit 2; }

VERSION="${TAG#v}"
NAME="DC-Studio-$VERSION-arm64"
DMG="$ROOT/dist/$NAME.dmg"
APP="$ROOT/dist/DC Studio.app"

cd "$ROOT"

# --- the tag has to exist, be annotated, and be what we are standing on ----
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || { echo "no such tag: $TAG"; exit 1; }
[ "$(git cat-file -t "$TAG")" = tag ] \
    || { echo "$TAG is a lightweight tag; the release notes come from an annotated one"; exit 1; }
[ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] \
    || { echo "$TAG does not point at HEAD"; exit 1; }
[ -z "$(git status --porcelain)" ] \
    || { echo "working tree is dirty — commit or stash first"; exit 1; }

cargo test --manifest-path core/Cargo.toml

VERSION="$VERSION" "$ROOT/scripts/make-release.sh"

# --- the guard -------------------------------------------------------------
# make-release.sh says what it did, but says it in passing; a release is the
# wrong place to trust a log line. Ask the system instead.
xcrun stapler validate "$DMG" >/dev/null \
    || { echo "refusing to publish: $NAME.dmg has no stapled ticket"; exit 1; }
xcrun stapler validate "$APP" >/dev/null \
    || { echo "refusing to publish: the app inside has no stapled ticket"; exit 1; }
spctl --assess --type open --context context:primary-signature "$DMG" \
    || { echo "refusing to publish: Gatekeeper rejects the disk image"; exit 1; }

# --- release notes = the annotated tag's message ---------------------------
SHA="$(cut -d' ' -f1 "$DMG.sha256")"
ENGINE="$( { echo uci; echo quit; } | stockfish | sed -n 's/^id name //p' | head -1)"
git tag -l --format='%(contents)' "$TAG" > dist/WHATSNEW.md
python3 - <<'EOF'
import pathlib
tmpl = pathlib.Path(".github/release-notes.tmpl.md").read_text()
notes = pathlib.Path("dist/WHATSNEW.md").read_text().strip()
pathlib.Path("dist/NOTES.md").write_text(tmpl.replace("@NOTES@", notes))
EOF
sed -i '' -e "s|@DMG@|$NAME.dmg|g" -e "s|@SHA@|$SHA|g" \
    -e "s|@ENGINE@|$ENGINE|g" -e "s|@TAG@|$TAG|g" dist/NOTES.md
cat dist/NOTES.md
echo
read -r -p "publish $TAG to GitHub? [y/N] " reply
[ "$reply" = y ] || { echo "stopped; nothing published"; exit 0; }

git push origin "$TAG"
gh release create "$TAG" \
    --title "DC Studio $VERSION" \
    --notes-file dist/NOTES.md \
    "$DMG" "$DMG.sha256"

# The website sends every download through dancechess.com/dl/dmg, which is a
# redirect carrying this version number — it has to move with the release or
# the download button keeps handing out the previous one.
DL_RULE="$HOME/dancechess.github.com/product/www/tools/dl-rule.py"
if [ -x "$DL_RULE" ]; then
    "$DL_RULE" "$VERSION"
else
    echo "note: update dancechess.com/dl/dmg by hand — tools/dl-rule.py not found"
fi
echo
echo "still to do by hand:"
echo "  www:  python3 tools/changelog.py && commit && push"
echo "  tap:  version + sha256 in Casks/d/dc-studio.rb, then push"
echo "        sha256 $(cut -d' ' -f1 "$DMG.sha256")"
