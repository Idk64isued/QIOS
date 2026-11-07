#!/bin/bash
# Development checkout: fetch pinned upstream tools locally, enable one instance.
# The payload carries its source inputs and redistribution notices.
set -euo pipefail
[ "$#" = 1 ] || { echo 'usage: enable.sh INSTANCE-UUID' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="${LTM_DEVELOPER_STATE_DIR:-$HOME/Library/Application Support/Light Touch/DeveloperSSH}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ltm-developer-enable.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
swift build -c release -q --package-path "$ROOT/tools/device-access"
ln -s "$(swift build -c release --package-path "$ROOT/tools/device-access" --show-bin-path)/device-access" "$TMP/access"
if [ ! -f "$STATE/payload/developer-tools.json" ]; then
    "$ROOT/tools/developer-packages/fetch.sh" "$STATE/payload"
fi
"$TMP/access" enable --instance "$1" --state "$STATE"
