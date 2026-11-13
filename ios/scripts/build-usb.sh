#!/bin/bash
# build-usb.sh — Cross-compile the USB/install stack for iOS (arm64).
# Probe script: runs in CI as a non-blocking job to see how far the build gets.
# The full chain: libplist → libimobiledevice-glue → libusbmuxd → libimobiledevice
#
# These are needed for the Mac-style IPA install path (AFC + installation_proxy
# over the in-process usbmuxd fork). Until this builds cleanly for iOS, IPA
# install uses the guest agent fallback.
#
# NOTE: This is a PROBE — it intentionally continues past failures to discover
# what needs fixing. Do NOT use set -e here.
set -uo pipefail

PREFIX="$(pwd)/ios-usb-prefix"
SRCDIR="$(pwd)/usb-sources"
LOGDIR="$(pwd)/usb-logs"
mkdir -p "$PREFIX" "$SRCDIR" "$LOGDIR"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios16.0"
CC="$(xcrun --sdk iphoneos -f clang)"
export CC
export CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2"
export LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

TOTAL=0
PASSED=0

build_one() {
    local name="$1" url="$2" branch="${3:-main}" extra="${4:-}"
    TOTAL=$((TOTAL + 1))
    echo "==> [$TOTAL] Building $name …"
    local dir="$SRCDIR/$name"
    if [ ! -d "$dir" ]; then
        git clone --depth 1 -b "$branch" "$url" "$dir" 2>&1 | tail -2
    fi
    pushd "$dir" > /dev/null

    local built=0

    # 1. Try meson first (libplist ≥ 2.4 dropped autotools)
    if [ -f meson.build ] && command -v meson &>/dev/null; then
        echo "   Using meson…"
        # Create a cross file for iOS arm64
        local crossfile="$dir/ios-cross.txt"
        cat > "$crossfile" <<CROSS
[binaries]
c = '$CC'
ar = '$(xcrun --sdk iphoneos -f ar)'
strip = '$(xcrun --sdk iphoneos -f strip)'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=16.0', '-O2']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=16.0']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
sys_root = '$SDK'
CROSS
        meson setup build-ios \
            --cross-file "$crossfile" \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dcython=disabled \
            >> "$LOGDIR/$name.log" 2>&1 || {
                echo "   meson setup FAILED (see $LOGDIR/$name.log)"
                popd > /dev/null; return 1
            }
        ninja -C build-ios >> "$LOGDIR/$name.log" 2>&1 || {
            echo "   ninja FAILED (see $LOGDIR/$name.log)"
            popd > /dev/null; return 1
        }
        meson install -C build-ios >> "$LOGDIR/$name.log" 2>&1 || {
            echo "   meson install FAILED (see $LOGDIR/$name.log)"
            popd > /dev/null; return 1
        }
        built=1
    fi

    # 2. Try autotools
    if [ "$built" -eq 0 ]; then
        if [ -f autogen.sh ]; then
            NOCONFIGURE=1 ./autogen.sh >> "$LOGDIR/$name.log" 2>&1 || true
        fi
        if [ -f configure.ac ] && [ ! -f configure ]; then
            autoreconf -fi >> "$LOGDIR/$name.log" 2>&1 || true
        fi

        if [ -f configure ]; then
            echo "   Using autotools…"
            ./configure \
                --host=aarch64-apple-darwin \
                --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --without-cython \
                $extra \
                >> "$LOGDIR/$name.log" 2>&1 || {
                    echo "   configure FAILED (see $LOGDIR/$name.log)"
                    popd > /dev/null; return 1
                }
            make -j"$(sysctl -n hw.ncpu)" >> "$LOGDIR/$name.log" 2>&1 || {
                echo "   make FAILED (see $LOGDIR/$name.log)"
                popd > /dev/null; return 1
            }
            make install >> "$LOGDIR/$name.log" 2>&1 || {
                echo "   install FAILED (see $LOGDIR/$name.log)"
                popd > /dev/null; return 1
            }
            built=1
        fi
    fi

    # 3. Try cmake
    if [ "$built" -eq 0 ] && [ -f CMakeLists.txt ]; then
        echo "   Using cmake…"
        cmake -B build-ios \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
            -DBUILD_SHARED_LIBS=OFF \
            >> "$LOGDIR/$name.log" 2>&1 || {
                echo "   cmake FAILED (see $LOGDIR/$name.log)"
                popd > /dev/null; return 1
            }
        cmake --build build-ios -- -j"$(sysctl -n hw.ncpu)" >> "$LOGDIR/$name.log" 2>&1 || {
            echo "   cmake build FAILED (see $LOGDIR/$name.log)"
            popd > /dev/null; return 1
        }
        cmake --install build-ios >> "$LOGDIR/$name.log" 2>&1 || {
            echo "   cmake install FAILED (see $LOGDIR/$name.log)"
            popd > /dev/null; return 1
        }
        built=1
    fi

    if [ "$built" -eq 0 ]; then
        echo "   No meson.build, configure, or CMakeLists.txt found"
        popd > /dev/null; return 1
    fi

    echo "   $name OK"
    PASSED=$((PASSED + 1))
    popd > /dev/null
}

# 1. libplist (no deps beyond system; recent versions use meson)
build_one libplist "https://github.com/libimobiledevice/libplist.git" master \
    "--without-cython" || echo "   (continuing despite failure)"

# 2. libimobiledevice-glue (depends on libplist)
build_one libimobiledevice-glue "https://github.com/libimobiledevice/libimobiledevice-glue.git" master \
    "" || echo "   (continuing despite failure)"

# 3. libusbmuxd (depends on libplist, glue)
# Note: on iOS we won't have a real usbmuxd daemon; the emulator's built-in USB
# bridge acts as one. libusbmuxd is the client library that talks to it.
build_one libusbmuxd "https://github.com/libimobiledevice/libusbmuxd.git" master \
    "" || echo "   (continuing despite failure)"

# 4. libimobiledevice (depends on all above + OpenSSL)
# The Mac app uses a patched fork with SSLv3 support. For the probe we try stock.
build_one libimobiledevice "https://github.com/libimobiledevice/libimobiledevice.git" master \
    "--with-openssl --without-inotify" || echo "   (continuing despite failure)"

echo ""
echo "==> USB stack probe finished: $PASSED/$TOTAL succeeded."
if [ "$PASSED" -lt "$TOTAL" ]; then
    echo "    Some components failed. Check logs in $LOGDIR/"
    echo "    This is expected — the probe finds what needs fixing."
else
    echo "    All components built! Libraries in $PREFIX/lib/"
fi

# Always exit 0 — this is a probe, not a gate
exit 0
