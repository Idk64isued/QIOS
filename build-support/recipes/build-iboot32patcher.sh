#!/bin/bash
# Build iBoot32Patcher (arm64, macOS 14) from the pinned archive in build-support/dependencies.json's
# "tools" group, which `scripts/ltm-build sources fetch` fetched into SRC-DIR, with build-support/patches/
# iBoot32Patcher-ltm.patch applied (aligned xrefs and ABI-checked RSA bypass; smoke #48/#50).
# OUT-DIR ends up with the binary, the upstream LICENSE (GPL-3.0), the patch, SOURCE.txt and build.json
# (commit, license, sha256s). LTM_ARCH (default arm64) names the slices, e.g. "arm64 x86_64" for the
# universal app (scripts/vendor). Called by build-package-native.sh and scripts/vendor, which ships OUT-DIR's
# LICENSE, patch and SOURCE.txt.
#
#     build-iboot32patcher.sh SRC-DIR OUT-DIR
set -euo pipefail
SRC_DIR="${1:?usage: build-iboot32patcher.sh src-dir out-dir}"
OUT="${2:?usage: build-iboot32patcher.sh src-dir out-dir}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH_FLAGS=""
for arch in ${LTM_ARCH:-arm64}; do ARCH_FLAGS="$ARCH_FLAGS-arch $arch "; done
DEPS="$HERE/build-support/dependencies.json"
i=0
# plutil fails past the last package (set -e doesn't reach a loop condition), which ends the search.
while name="$(plutil -extract "packages.$i.name" raw -o - "$DEPS" 2>/dev/null)" && [ "$name" != iBoot32Patcher ]; do
    i=$((i + 1))
done
[ "$name" = iBoot32Patcher ] || { echo "no iBoot32Patcher package in $DEPS" >&2; exit 1; }
iboot() { plutil -extract "packages.$i.$1" raw -o - "$DEPS"; }
ARCHIVE="$(iboot archive)" COMMIT="$(iboot version)" LICENSE="$(iboot license)" URL="$(iboot url)"
[ -f "$SRC_DIR/$ARCHIVE" ] || { echo "missing $SRC_DIR/$ARCHIVE; run scripts/ltm-build sources fetch --group tools" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
tar -xzf "$SRC_DIR/$ARCHIVE" -C "$OUT" --strip-components=1
PATCH="$HERE/build-support/patches/iBoot32Patcher-ltm.patch"
(cd "$OUT" && patch -p1 --quiet < "$PATCH")
cp "$PATCH" "$OUT/"
(cd "$OUT" && make CC=/usr/bin/clang CFLAGS="-O2 $ARCH_FLAGS-mmacosx-version-min=14.0 -Wno-multichar -Wno-int-conversion" > "$OUT/make.log" 2>&1)
"$HERE/scripts/ltm-build" check-macho --no-weak-imports --minos 14.0 "$OUT/iBoot32Patcher"
printf '%s\n' "iBoot32Patcher $COMMIT: $URL" "License: $LICENSE (LICENSE alongside)" \
    "Modified: $(basename "$PATCH") (alongside) applied to that source." \
    "Built by build-support/recipes/build-iboot32patcher.sh: make CC=clang CFLAGS='-O2 $ARCH_FLAGS-mmacosx-version-min=14.0'" \
    "firmwarekit runs it as a separate process for the iPad's real-iBoot boot chain (--rsa --debug -b boot-args)." \
    > "$OUT/SOURCE.txt"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
printf '{\n  "archive_sha256": "%s",\n  "binary": "%s",\n  "commit": "%s",\n  "license": "%s",\n  "patch_sha256": "%s",\n  "sha256": "%s"\n}\n' \
    "$(sha "$SRC_DIR/$ARCHIVE")" "$OUT/iBoot32Patcher" "$COMMIT" "$LICENSE" "$(sha "$PATCH")" "$(sha "$OUT/iBoot32Patcher")" > "$OUT/build.json"
echo "built $OUT/iBoot32Patcher ($COMMIT, $LICENSE)"
