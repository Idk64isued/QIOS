#!/bin/bash
# build-usb.sh — Cross-compile the USB/install stack for iOS (arm64).
# Probe script: runs in CI as a non-blocking job to see how far the build gets.
# The full chain: libplist → libimobiledevice-glue → libusbmuxd → libimobiledevice
#
# These are needed for the Mac-style IPA install path (AFC + installation_proxy
# over the in-process usbmuxd fork). Until this builds cleanly for iOS, IPA
# install uses the guest agent fallback.
set -euo pipefail

PREFIX="$(pwd)/ios-usb-prefix"
SRCDIR="$(pwd)/usb-sources"
LOGDIR="$(pwd)/usb-logs"
mkdir -p "$PREFIX" "$SRCDIR" "$LOGDIR"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios16.0"
CC="$(xcrun --sdk iphoneos -f clang)"
export CC
export CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -fembed-bitcode -O2"
export LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

FAILED=0

build_one() {
    local name="$1" url="$2" branch="${3:-main}" extra="${4:-}"
    echo "==> Building $name …"
    local dir="$SRCDIR/$name"
    if [ ! -d "$dir" ]; then
        git clone --depth 1 -b "$branch" "$url" "$dir" 2>&1 | tail -2
    fi
    cd "$dir"

    # Many of these use autotools
    if [ -f autogen.sh ]; then
        NOCONFIGURE=1 ./autogen.sh >> "$LOGDIR/$name.log" 2>&1 || true
    fi

    if [ -f configure.ac ] && [ ! -f configure ]; then
        autoreconf -fi >> "$LOGDIR/$name.log" 2>&1 || true
    fi

    if [ -f configure ]; then
        ./configure \
            --host=aarch64-apple-darwin \
            --prefix="$PREFIX" \
            --disable-shared \
            --enable-static \
            --without-cython \
            $extra \
            >> "$LOGDIR/$name.log" 2>&1 || {
                echo "   configure FAILED (see $LOGDIR/$name.log)"
                FAILED=1; return 1
            }
        make -j"$(sysctl -n hw.ncpu)" >> "$LOGDIR/$name.log" 2>&1 || {
            echo "   make FAILED (see $LOGDIR/$name.log)"
            FAILED=1; return 1
        }
        make install >> "$LOGDIR/$name.log" 2>&1 || {
            echo "   install FAILED (see $LOGDIR/$name.log)"
            FAILED=1; return 1
        }
    elif [ -f CMakeLists.txt ]; then
        cmake -B build-ios \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
            -DBUILD_SHARED_LIBS=OFF \
            >> "$LOGDIR/$name.log" 2>&1 || {
                echo "   cmake FAILED"; FAILED=1; return 1
            }
        cmake --build build-ios -- -j"$(sysctl -n hw.ncpu)" >> "$LOGDIR/$name.log" 2>&1 || {
            echo "   cmake build FAILED"; FAILED=1; return 1
        }
        cmake --install build-ios >> "$LOGDIR/$name.log" 2>&1 || {
            echo "   cmake install FAILED"; FAILED=1; return 1
        }
    else
        echo "   No configure or CMakeLists.txt found"
        FAILED=1; return 1
    fi

    echo "   $name OK"
    cd -
}

# 1. libplist (no deps beyond system)
build_one libplist "https://github.com/libimobiledevice/libplist.git" master \
    "--without-cython"

# 2. libimobiledevice-glue (depends on libplist)
build_one libimobiledevice-glue "https://github.com/libimobiledevice/libimobiledevice-glue.git" master

# 3. libusbmuxd (depends on libplist, glue)
# Note: on iOS we won't have a real usbmuxd daemon; the emulator's built-in USB
# bridge acts as one. libusbmuxd is the client library that talks to it.
build_one libusbmuxd "https://github.com/libimobiledevice/libusbmuxd.git" master

# 4. libimobiledevice (depends on all above + OpenSSL)
# The Mac app uses a patched fork with SSLv3 support. For the probe we try stock.
build_one libimobiledevice "https://github.com/libimobiledevice/libimobiledevice.git" master \
    "--with-openssl --without-inotify"

echo ""
echo "==> USB stack probe finished."
if [ "$FAILED" -ne 0 ]; then
    echo "    Some components failed. Check logs in $LOGDIR/"
    echo "    This is expected — the probe finds what needs fixing."
else
    echo "    All components built! Libraries in $PREFIX/lib/"
fi

# Always upload logs regardless of failure
exit 0
