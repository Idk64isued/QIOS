#!/bin/bash
# ANGLE for iOS: libEGL.dylib and libGLESv2.dylib (Metal only, arm64, iOS 16) at the commit
# build-support/dependencies.json pins for the Mac app's ANGLE (the "ANGLE" package), plus ANGLE's include/ (what
# qemu-ios's ANGLE renderer builds against) and its licenses, into OUT-DIR. The iOS twin of
# build-support/recipes/build-angle.sh: same checkout, same patch, the same gn arguments plus the iOS target ones.
#
# With it the emulator draws the guest's OpenGL ES through ANGLE on Metal (gl-renderer=angle): ES 1.1 and ES 2.0
# guests alike, which the iPhone's own ES 1.1 context (the EAGL renderer) can't do for the ES 2.0 ones.
#
#     build-angle-ios.sh CHECKOUT OUT-DIR
set -euo pipefail
CHECKOUT="${1:?usage: build-angle-ios.sh checkout out-dir}"
OUT="${2:?usage: build-angle-ios.sh checkout out-dir}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$HERE/build-support/dependencies.json"
NINJA="${NINJA:-$(command -v ninja)}"
[ -x "$NINJA" ] || { echo "missing build tool: ninja" >&2; exit 1; }
COMMIT="$(jq -r '.packages[] | select(.name == "ANGLE") | .version' "$DEPS")"
TOOLS="$(jq -r '.packages[] | select(.name == "ANGLE") | .depot_tools' "$DEPS")"
URL="$(jq -r '.packages[] | select(.name == "ANGLE") | .repository' "$DEPS")"
[ -n "$COMMIT" ] && [ "$COMMIT" != null ] || { echo "no ANGLE package in $DEPS" >&2; exit 1; }
fetch() {   # DIR URL COMMIT
    git init -q "$1"
    git -C "$1" fetch -q --depth 1 "$2" "$3"
    git -C "$1" checkout -q --detach FETCH_HEAD
}
mkdir -p "$CHECKOUT"
CHECKOUT="$(cd "$CHECKOUT" && pwd)"
if [ "$(git -C "$CHECKOUT/angle" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ] || [ ! -f "$CHECKOUT/.synced" ]; then
    rm -rf "$CHECKOUT/angle" "$CHECKOUT/depot_tools" "$CHECKOUT/.synced"
    fetch "$CHECKOUT/angle" "$URL" "$COMMIT"
    fetch "$CHECKOUT/depot_tools" https://chromium.googlesource.com/chromium/tools/depot_tools.git "$TOOLS"
    cat > "$CHECKOUT/.gclient" <<EOF
solutions=[{"name":"angle","url":"$URL","managed":False,"custom_deps":{},"custom_vars":{"checkout_angle_cl_deps":False,"checkout_angle_dawn_deps":False,"checkout_angle_internal":False,"checkout_angle_restricted_traces":False,"checkout_angle_mesa":False,"download_remoteexec_cfg":False}}]
target_os=["ios"]
EOF
    (cd "$CHECKOUT" && PATH="$CHECKOUT/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0 gclient sync --shallow --no-history -j6)
    touch "$CHECKOUT/.synced"
fi
A="$CHECKOUT/angle"
PATCH="$HERE/build-support/patches/angle-metal-strong.patch"
git -C "$A" apply --reverse --check "$PATCH" 2>/dev/null || git -C "$A" apply "$PATCH"
ARGS='is_debug=false is_component_build=false angle_enable_metal=true angle_enable_gl=false angle_enable_vulkan=false'
ARGS="$ARGS angle_enable_null=false angle_build_tests=false angle_build_all=false angle_has_frame_capture=false"
ARGS="$ARGS angle_enable_perfetto=false angle_has_astc_encoder=false use_remoteexec=false use_siso=false"
ARGS="$ARGS clang_use_chrome_plugins=false use_custom_libcxx=false enable_dsyms=false"
ARGS="$ARGS target_os=\"ios\" target_cpu=\"arm64\" target_environment=\"device\" ios_deployment_target=\"16.0\""
ARGS="$ARGS ios_enable_code_signing=false"
BUILD="$A/out/ltm-ios"
(cd "$A" && buildtools/mac/gn gen "$BUILD" --args="$ARGS")
rm -rf "$OUT"
mkdir -p "$OUT/licenses"
"$NINJA" -C "$BUILD" -j"${LTM_JOBS:-$(sysctl -n hw.ncpu)}" libEGL libGLESv2 > "$OUT/ninja.log" 2>&1 \
    || { tail -60 "$OUT/ninja.log" >&2; exit 1; }
# A plain dylib, or the binary inside a .framework, depending on how ANGLE's gn packages iOS libraries.
for lib in libEGL libGLESv2; do
    src=""
    for c in "$BUILD/$lib.dylib" "$BUILD/$lib.framework/$lib"; do [ -f "$c" ] && { src="$c"; break; }; done
    [ -n "$src" ] || src="$(find "$BUILD" -maxdepth 3 \( -name "$lib.dylib" -o -path "*/$lib.framework/$lib" \) -type f | head -1)"
    [ -n "$src" ] || { echo "no $lib in $BUILD" >&2; ls "$BUILD" >&2; exit 1; }
    cp "$src" "$OUT/$lib.dylib"
    chmod 755 "$OUT/$lib.dylib"
    install_name_tool -id "@rpath/$lib.dylib" "$OUT/$lib.dylib"
done
# libEGL finds libGLESv2 beside itself, whatever name its build gave it.
old="$(otool -L "$OUT/libEGL.dylib" | awk '/libGLESv2/ {print $1; exit}')"
[ -z "$old" ] || [ "$old" = "@rpath/libGLESv2.dylib" ] || install_name_tool -change "$old" "@rpath/libGLESv2.dylib" "$OUT/libEGL.dylib"
for lib in libEGL libGLESv2; do
    install_name_tool -add_rpath @loader_path "$OUT/$lib.dylib" 2>/dev/null || true
    codesign -f -s - "$OUT/$lib.dylib"
    echo "$lib.dylib: $(otool -l "$OUT/$lib.dylib" | grep -A4 LC_BUILD_VERSION | grep -E 'platform|minos' | tr -s ' ' | tr '\n' ' ')"
done
cp -R "$A/include" "$OUT/include"
cp "$A/LICENSE" "$OUT/licenses/LICENSE"
cp "$A/third_party/abseil-cpp/LICENSE" "$OUT/licenses/LICENSE.abseil-cpp" 2>/dev/null || true
cp "$A/third_party/zlib/LICENSE" "$OUT/licenses/LICENSE.zlib" 2>/dev/null || true
printf '%s\n' "ANGLE $COMMIT: $URL (depot_tools $TOOLS), built by ios/scripts/build-angle-ios.sh: gn args $ARGS." \
    > "$OUT/licenses/SOURCE.txt"
ls -l "$OUT"/*.dylib
