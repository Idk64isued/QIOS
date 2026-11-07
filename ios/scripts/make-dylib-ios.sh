#!/bin/bash
# iOS twin of contrib/macos-app/make-dylib-macos.sh: relink an already-built qemu-system-arm as a dylib the app dlopens.
#     make-dylib-ios.sh QEMU_SRC BUILD_DIR OUT_DYLIB_NAME
# Works for the JIT build and the --enable-tcg-interpreter build (picks tcg/tci when the build is TCI).
set -eu
SRC="$1"; BUILD="$2"; LIBNAME="$3"; OUT="$BUILD/$LIBNAME"
cd "$BUILD"
DEP_CFLAGS="$(pkg-config --cflags glib-2.0 pixman-1)"
eval "CC_ARGV=($(jq -r ".host.c.exelist | @sh" meson-info/intro-compilers.json))"
if grep -q "CONFIG_TCG_INTERPRETER" config-host.h 2>/dev/null || grep -q "CONFIG_TCG_INTERPRETER" config-target.h 2>/dev/null; then TCG_HOST=tci; else TCG_HOST=aarch64; fi
for f in "$SRC/contrib/ios-app/qemu-ios-entry.c" "$SRC/contrib/ios-app/qemu-ios-ui.c" "$SRC/contrib/macos-app/qemu-macos-extras.c"; do
    o="$(basename "${f%.c}").o"
    "${CC_ARGV[@]}" -c "$f" -o "$o" -I. -I.. -Iqapi -Itrace -Iui -I"$SRC/contrib/ios-app" -I"$SRC/contrib/macos-app" $DEP_CFLAGS \
        -iquote . -iquote "$SRC" -iquote "$SRC/include" -iquote "$SRC/host/include/aarch64" -iquote "$SRC/host/include/generic" \
        -iquote "$SRC/tcg/$TCG_HOST" -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -std=gnu11 -O2
done
ninja qemu-system-arm >/dev/null
eval "LINK=($(ninja -t commands qemu-system-arm-unsigned | tail -1))"
ARGS=(); skip=0
for a in "${LINK[@]}"; do
    if [ $skip = 1 ]; then skip=0; continue; fi
    case "$a" in
        -o) skip=1 ;;
        *system_main.c.o) ARGS+=(qemu-ios-entry.o qemu-ios-ui.o qemu-macos-extras.o) ;;
        @*) ;;
        *) ARGS+=("$a") ;;
    esac
done
# the app ABI: everything the macOS build exports, plus the foreground hook iOS needs
{ sed -n "/<<.SYMS.$/,/^SYMS$/p" "$SRC/contrib/macos-app/make-dylib-macos.sh" | sed "1d;\$d"; echo _qemu_ios_set_foreground; } | sort -u > ios-exports.syms
ARGS+=(-dynamiclib -o "$OUT" -install_name "@rpath/$LIBNAME" "-Wl,-exported_symbols_list,$BUILD/ios-exports.syms" -Wl,-undefined,dynamic_lookup)
"${ARGS[@]}"
codesign -f -s - "$OUT"
echo "built $OUT ($TCG_HOST)"
