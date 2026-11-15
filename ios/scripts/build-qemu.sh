#!/bin/bash
# Patches qemu-ios, then builds libqemu-arm.dylib (JIT) and libqemu-arm-tci.dylib (interpreter fallback) for iOS arm64.
#     [LTM_ANGLE=angle-out] build-qemu.sh QEMU_SRC DEPS_PREFIX OUT_DIR
# LTM_ANGLE (build-angle-ios.sh's output): also build the ANGLE renderer beside the EAGL one (patches/qemu-ios/0009).
set -euo pipefail
QEMU="$(cd "${1:?qemu-ios checkout}" && pwd)"; P="$(cd "${2:?deps prefix}" && pwd)"; OUT="${3:?out dir}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"; FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0"
JOBS="$(sysctl -n hw.ncpu)"
cd "$QEMU"
# Every patch has to apply: one that silently didn't would ship an emulator without its fix. A tree this script
# already patched says so with a marker naming the patch set, so a local rebuild doesn't try them twice.
MARK=".ios-patches-applied"; WANT="$(cat "$HERE"/../patches/qemu-ios/*.patch | shasum | cut -c1-16)"
if [ -f "$MARK" ] && [ "$(cat "$MARK")" = "$WANT" ]; then
    echo "qemu-ios patches already applied ($WANT)"
else
    for p in "$HERE"/../patches/qemu-ios/*.patch; do
        if git apply --check "$p" 2>/dev/null; then git apply "$p"; echo "applied $(basename "$p")"
        else echo "::error::$(basename "$p") does not apply to this qemu-ios (a fresh checkout of the pinned commit is needed)" >&2; git apply --check "$p"; exit 1; fi
    done
    echo "$WANT" > "$MARK"
fi
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=
# --disable-qom-cast-debug: QEMU checks every QOM cast (each device register access casts its device) by looking the
# type up, unless told not to; a release build has no use for the check, and the phone pays for it on every access.
build() {   # NAME DYLIB EXTRA-CONFIGURE-ARGS...
    local name="$1" dylib="$2"; shift 2
    rm -rf "$OUT/build-$name"; mkdir "$OUT/build-$name"; cd "$OUT/build-$name"
    "$QEMU/configure" --cross-prefix= --cpu=aarch64 --cc="clang $FLAGS" --cxx="clang++ $FLAGS" --objcc="clang $FLAGS" \
        --target-list=arm-softmmu --without-default-features --enable-pixman --enable-slirp --enable-nettle --disable-pie \
        --disable-tools --disable-docs --audio-drv-list= --python="${QEMU_PYTHON:-python3}" \
        --disable-qom-cast-debug \
        --extra-cflags="-I$P/include -miphoneos-version-min=16.0 -DGLES_SILENCE_DEPRECATION -ferror-limit=0" --extra-ldflags="-L$P/lib -lcrypto -miphoneos-version-min=16.0" \
        ${LTM_ANGLE:+"-Dltm_angle_prefix=$LTM_ANGLE"} "$@"
    ninja -k 0 -j"$JOBS" qemu-system-arm   # -k 0: keep going, so one run reports every failing file
    bash "$HERE/make-dylib-ios.sh" "$QEMU" "$PWD" "$dylib"
    cp "$dylib" "$OUT/"
}
build jit libqemu-arm.dylib
build tci libqemu-arm-tci.dylib --enable-tcg-interpreter
ls -l "$OUT"/*.dylib
