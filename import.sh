#!/bin/bash
#     git clone https://github.com/Idk64isued/QIOS && cd QIOS
#     bash /path/to/ltm-ios/import.sh /path/to/LightTouchMac-1_0-2026_11_05.zip
# It puts the LightTouchMac source (GPL-2.0-or-later, so your GPLv3 LICENSE stays) at the repo root, then adds the iOS port
# (ios/ and the two workflows). Review with `git status`, then commit and push.
set -euo pipefail
[ -d .git ] || { echo "Run this inside your QIOS clone (cd QIOS first), not from your home folder." >&2; exit 1; }
ZIP="${1:?path to the LightTouchMac source (zip or folder)}"; HERE="$(cd "$(dirname "$0")" && pwd)"
KEEP="$(mktemp)"; [ -f LICENSE ] && cp LICENSE "$KEEP"
if [ -d "$ZIP" ]; then SRC="$(cd "$ZIP" && pwd)"            # a folder, e.g. a clone of samhenrigold/LightTouchMac
else
    TMP="$(mktemp -d)"; unzip -q "$ZIP" -d "$TMP"
    XP="$(find "$TMP" -maxdepth 3 -name LightTouchMac.xcodeproj | head -1)"
    [ -n "$XP" ] || { echo "This zip has no LightTouchMac.xcodeproj, so it is not the source. A built app zip will not work." >&2; exit 1; }
    SRC="$(dirname "$XP")"
fi
[ -f "$SRC/LightTouchMac.xcodeproj/project.pbxproj" ] || { echo "$SRC is not the LightTouchMac source" >&2; exit 1; }
tar -C "$SRC" --exclude=.git -cf - . | tar -xf -          # never touches this repo's .git
[ -s "$KEEP" ] && cp "$KEEP" LICENSE
cp -a "$HERE/ios" ./ios
mkdir -p .github/workflows && cp "$HERE"/.github/workflows/*.yml .github/workflows/
mv README.md UPSTREAM-README.md
cp "$HERE/README.md" ./README.md
echo "Done. Next: git add -A && git commit -m 'LightTouchMac + iOS port' && git push"
