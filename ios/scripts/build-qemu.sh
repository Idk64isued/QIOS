#!/bin/bash
# Patches qemu-ios, then builds libqemu-arm.dylib (JIT) and libqemu-arm-tci.dylib (interpreter fallback) for iOS arm64.
#     build-qemu.sh QEMU_SRC DEPS_PREFIX OUT_DIR
set -euo pipefail
QEMU="$(cd "${1:?qemu-ios checkout}" && pwd)"; P="$(cd "${2:?deps prefix}" && pwd)"; OUT="${3:?out dir}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"; FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0"
JOBS="$(sysctl -n hw.ncpu)"
cd "$QEMU"
for p in "$HERE"/../patches/qemu-ios/*.patch; do git apply --check "$p" 2>/dev/null && git apply "$p" || echo "patch $p: already applied or does not apply" >&2; done
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=
build() {   # NAME DYLIB EXTRA-CONFIGURE-ARGS...
    local name="$1" dylib="$2"; shift 2
    rm -rf "$OUT/build-$name"; mkdir "$OUT/build-$name"; cd "$OUT/build-$name"
    "$QEMU/configure" --cross-prefix= --cpu=aarch64 --cc="clang $FLAGS" --cxx="clang++ $FLAGS" --objcc="clang $FLAGS" \
        --target-list=arm-softmmu --without-default-features --enable-pixman --enable-slirp --enable-nettle --disable-pie \
        --disable-tools --disable-docs --audio-drv-list= --python="${QEMU_PYTHON:-python3}" \
        --extra-cflags="-I$P/include -miphoneos-version-min=16.0" --extra-ldflags="-L$P/lib -lcrypto -miphoneos-version-min=16.0" "$@"
    ninja -j"$JOBS" qemu-system-arm
    bash "$HERE/make-dylib-ios.sh" "$QEMU" "$PWD" "$dylib"
    cp "$dylib" "$OUT/"
}
build jit libqemu-arm.dylib
build tci libqemu-arm-tci.dylib --enable-tcg-interpreter
ls -l "$OUT"/*.dylib
