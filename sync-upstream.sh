#!/bin/bash
# sync-upstream.sh — Replace upstream LightTouchMac files in your QIOS clone
# with the latest from the LightTouchtest fork, keeping the iOS port intact.
#
# Usage:  cd ~/QIOS && bash /path/to/sync-upstream.sh
#
# What it does:
#   1. Clones https://github.com/Idk64isued/LightTouchtest (shallow)
#   2. Removes all upstream files (everything except ios/, .github/, README.md,
#      UPSTREAM-README.md, LICENSE, LICENSE-GPL-2.0.txt, and .git/)
#   3. Copies the fork's files in
#   4. Renames the fork's README → UPSTREAM-README.md
#   5. Leaves ios/ and .github/ untouched
set -euo pipefail

[ -d .git ] && [ -d Packages/HostRuntime ] || {
    echo "Run this inside your QIOS clone (cd QIOS first)." >&2; exit 1
}

FORK_URL="https://github.com/Idk64isued/LightTouchtest.git"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Cloning $FORK_URL …"
git clone --depth 1 "$FORK_URL" "$TMP/src" 2>&1 | tail -2

echo "==> Removing old upstream files …"
# Delete everything except the preserve list
find . -maxdepth 1 \
    ! -name '.' \
    ! -name '.git' \
    ! -name 'ios' \
    ! -name '.github' \
    ! -name 'README.md' \
    ! -name 'UPSTREAM-README.md' \
    ! -name 'LICENSE' \
    ! -name 'LICENSE-GPL-2.0.txt' \
    -exec rm -rf {} +

echo "==> Copying new upstream files …"
# Copy everything from the fork except .git
(cd "$TMP/src" && tar --exclude=.git --exclude=.github -cf - .) | tar -xf -

# Move the fork's README to UPSTREAM-README.md
[ -f README.md ] && {
    # If the fork shipped a README, it's now at ./README.md — but our README.md
    # is the iOS port readme. Fork README → UPSTREAM-README.md.
    # Check if this is our iOS readme (has "StikDebug" in it) or the fork's
    if ! grep -q "StikDebug" README.md 2>/dev/null; then
        mv README.md UPSTREAM-README.md
    fi
}

# Ensure our iOS README is in place
if [ ! -f README.md ] || ! grep -q "StikDebug" README.md 2>/dev/null; then
    cat > README.md << 'IOSREADME'
# Light Touch on iOS (StikDebug JIT, LiveContainer, GitHub Actions)

Port of LightTouchMac to iOS. Boots iPod touch 2G (n72ap-7E18, iPhone OS 3.1.3) in ~5–10 seconds with JIT.

## Quick start
1. Download `LightTouch.ipa` from Actions → iOS build
2. Sideload via SideStore/LiveContainer
3. Copy your prepared device to `LightTouch/Devices/` and boot ROMs to `LightTouch/Device/`
4. Enable JIT with StikDebug (universal.js for TXM devices) before launching
5. Tap the device to boot

## Build
GitHub Actions: `.github/workflows/ios.yml` — uses Xcode 26+ on macOS 26 runner.

## License
GPL-2.0 — see LICENSE-GPL-2.0.txt
IOSREADME
fi

echo "==> Upstream synced. Files preserved: ios/, .github/, README.md, LICENSE*"
echo "    Next: git add -A && git diff --cached --stat"
echo "    Then: git commit -m 'Sync upstream LightTouchtest' && git pull --rebase && git push"
echo "    Also set MacFiles.releaseTag (ios/App/Sources/FirmwareLibrary.swift) to the Mac release built from these sources."
