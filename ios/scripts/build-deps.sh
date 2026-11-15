#!/bin/bash
# Cross-builds the libraries libqemu-arm needs for iOS arm64 (static, into $OUT/prefix), at the versions and
# checksums build-support/dependencies.json pins. Run from the LightTouchMac checkout on a Mac with Xcode:
#     ios/scripts/build-deps.sh /path/to/qemu-ios /path/to/work-dir
# Needs: meson ninja pkg-config python3 curl (brew install meson ninja pkg-config).
set -euo pipefail
QEMU="${1:?qemu-ios checkout}"; ROOT="${2:?new work directory}"
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
[ ! -e "$ROOT" ] || { echo "use a new work directory: $ROOT" >&2; exit 1; }
mkdir -p "$ROOT"/{src,build,logs,prefix/lib/pkgconfig}; ROOT="$(cd "$ROOT" && pwd)"; P="$ROOT/prefix"
JOBS="$(sysctl -n hw.ncpu)"
MIN=16.0
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun -f clang)"
FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN"
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH SDKROOT

# --- pinned sources -----------------------------------------------------------------------------------------
fetch() {   # NAME... : download + sha256-verify the dependencies.json entries
python3 - "$SRC/build-support/dependencies.json" "$ROOT/src" "$@" <<'PY'
import json, sys, hashlib, urllib.request, os, time
deps = {p["name"]: p for p in json.load(open(sys.argv[1]))["packages"]}
for name in sys.argv[3:]:
    p = deps[name]; dest = os.path.join(sys.argv[2], p["archive"])
    if not os.path.exists(dest):
        last = None
        for attempt in range(1, 7):
            try:
                print("fetch", p["url"], f"(attempt {attempt})", flush=True)
                req = urllib.request.Request(p["url"], headers={"User-Agent": "ltm-ios-build"})
                with urllib.request.urlopen(req, timeout=120) as r, open(dest + ".part", "wb") as f:
                    while chunk := r.read(1 << 20): f.write(chunk)
                os.replace(dest + ".part", dest)
                break
            except Exception as ex:
                last = ex
                print("  failed:", ex, flush=True)
                time.sleep(5 * attempt)
        else:
            sys.exit(f"{name}: could not download after 6 attempts: {last}")
    h = hashlib.sha256(open(dest, "rb").read()).hexdigest()
    if h != p["sha256"]: sys.exit(f"{name}: sha256 mismatch ({h})")
PY
}
fetch glib pcre2 pixman slirp proxy-libintl ffmpeg openssl nettle
cd "$ROOT/build"
for a in glib-2.88.3.tar.xz pcre2-10.48.tar.bz2 pixman-0.46.4.tar.gz libslirp-v4.9.4.tar.gz ffmpeg-9.0.1.tar.xz openssl-3.6.3.tar.gz nettle-3.10.2.tar.gz; do tar -xf "$ROOT/src/$a"; done
tar -xf "$ROOT/src/proxy-libintl-0.5.tar.gz" -C glib-2.88.3/subprojects

# --- meson cross file ---------------------------------------------------------------------------------------
cat > "$ROOT/ios-arm64.meson" <<EOM
[binaries]
c = ['$CLANG', '-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN']
cpp = ['$(xcrun -f clang++)', '-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN']
objc = ['$CLANG', '-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN']
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'
pkg-config = '$(command -v pkg-config)'
[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
EOM
CROSS=(--cross-file "$ROOT/ios-arm64.meson")

# The iOS SDK ships zlib and iconv but NOT libffi (the macOS SDK does), so libffi is built from source below.
printf "Name: zlib\nDescription: iOS SDK zlib\nVersion: 1.2.12\nLibs: -lz\nCflags:\n" > "$P/lib/pkgconfig/zlib.pc"

log() { echo "== $*"; }
# whenever a step fails, show the end of the newest per-library log in the Actions output
trap 'f=$(ls -t "$ROOT"/logs/*.log 2>/dev/null | head -1); [ -n "$f" ] && { echo "--- tail of $f"; tail -60 "$f"; }' ERR
# --- libffi (not in dependencies.json; pinned here, sha256 recorded when this script was written) ------------
log libffi
LIBFFI=libffi-3.4.8.tar.gz
LIBFFI_SHA256=bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b
[ -f "$ROOT/src/$LIBFFI" ] || curl -fsSL --retry 6 --retry-delay 5 --retry-all-errors -o "$ROOT/src/$LIBFFI" "https://github.com/libffi/libffi/releases/download/v3.4.8/$LIBFFI"
echo "$LIBFFI_SHA256  $ROOT/src/$LIBFFI" | shasum -a 256 -c - || { echo "libffi checksum mismatch" >&2; exit 1; }
tar -xf "$ROOT/src/$LIBFFI"
(cd libffi-3.4.8 && CC="$CLANG $FLAGS" ./configure --prefix="$P" --libdir="$P/lib" --host=aarch64-apple-darwin --disable-shared \
    --enable-static --disable-docs --disable-multi-os-directory >"$ROOT/logs/libffi.log" 2>&1 \
  && make -j"$JOBS" >>"$ROOT/logs/libffi.log" 2>&1 && make install >>"$ROOT/logs/libffi.log" 2>&1) \
  || { tail -40 "$ROOT/logs/libffi.log"; exit 1; }
# --- pcre2 --------------------------------------------------------------------------------------------------
log pcre2
(cd pcre2-10.48 && CC="$CLANG $FLAGS" ./configure --prefix="$P" --host=aarch64-apple-darwin --disable-shared --enable-static \
    --disable-pcre2grep-libz --disable-pcre2grep-libbz2 >"$ROOT/logs/pcre2.log" 2>&1 && make -j"$JOBS" >>"$ROOT/logs/pcre2.log" 2>&1 && make install >>"$ROOT/logs/pcre2.log" 2>&1)
# --- glib (+ proxy-libintl) -------------------------------------------------------------------------------
log glib
(cd glib-2.88.3 && patch -p1 < "$SRC/build-support/patches/glib-pipe2-availability.patch")
meson setup glib-out glib-2.88.3 "${CROSS[@]}" --prefix="$P" --buildtype=release -Ddefault_library=static -Dnls=disabled -Dtests=false \
    -Dintrospection=disabled -Dman-pages=disabled -Dlibmount=disabled -Dselinux=disabled -Dsysprof=disabled --wrap-mode=nodownload >"$ROOT/logs/glib.log" 2>&1 || { tail -50 "$ROOT/logs/glib.log"; exit 1; }
ninja -C glib-out -j"$JOBS" >>"$ROOT/logs/glib.log" 2>&1 && ninja -C glib-out install >>"$ROOT/logs/glib.log" 2>&1
# --- pixman -----------------------------------------------------------------------------------------------
log pixman
meson setup pixman-out pixman-0.46.4 "${CROSS[@]}" --prefix="$P" --buildtype=release -Ddefault_library=static -Dtests=disabled -Ddemos=disabled --wrap-mode=nofallback >"$ROOT/logs/pixman.log" 2>&1
ninja -C pixman-out -j"$JOBS" >>"$ROOT/logs/pixman.log" 2>&1 && ninja -C pixman-out install >>"$ROOT/logs/pixman.log" 2>&1
# --- libslirp, with the patches qemu-ios needs (same list its wrap uses) -----------------------------------
log slirp
for name in $(sed -n "s/^diff_files = //p" "$QEMU/subprojects/slirp.wrap" | tr -d ","); do
    f="$QEMU/subprojects/packagefiles/$name"; [ -f "$f" ] && (cd libslirp-v4.9.4 && patch -p1 < "$f")
done
meson setup slirp-out libslirp-v4.9.4 "${CROSS[@]}" --prefix="$P" --buildtype=release -Ddefault_library=static --wrap-mode=nofallback >"$ROOT/logs/slirp.log" 2>&1
ninja -C slirp-out -j"$JOBS" >>"$ROOT/logs/slirp.log" 2>&1 && ninja -C slirp-out install >>"$ROOT/logs/slirp.log" 2>&1
# --- OpenSSL (the boards' AES/SHA) -------------------------------------------------------------------------
log openssl
(cd openssl-3.6.3 && ./Configure ios64-xcrun no-shared no-tests no-docs no-apps --prefix="$P" --openssldir=/var/empty \
    "-miphoneos-version-min=$MIN" >"$ROOT/logs/openssl.log" 2>&1 && make -j"$JOBS" build_libs >>"$ROOT/logs/openssl.log" 2>&1 && make install_dev >>"$ROOT/logs/openssl.log" 2>&1)
# --- nettle (QEMU's cipher backend) -------------------------------------------------------------------------
log nettle
(cd nettle-3.10.2 && CC="$CLANG $FLAGS" ./configure --prefix="$P" --host=aarch64-apple-darwin --disable-shared --enable-static --disable-public-key \
    --disable-openssl --disable-documentation --disable-assembler --libdir="$P/lib" >"$ROOT/logs/nettle.log" 2>&1 && make -j"$JOBS" >>"$ROOT/logs/nettle.log" 2>&1 && make install >>"$ROOT/logs/nettle.log" 2>&1)
# --- FFmpeg: libavcodec/libavutil, with qemu-ios's H.264 patches, static ------------------------------------
log ffmpeg
(cd ffmpeg-9.0.1 && patch -p1 < "$QEMU/contrib/ffmpeg/h264-chunk-er.patch" && patch -p1 < "$QEMU/contrib/ffmpeg/h264-cavlc-pcm-offset.patch" \
  && ./configure --prefix="$P" --enable-cross-compile --arch=arm64 --target-os=darwin --cc="$CLANG $FLAGS" \
        --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-avdevice --disable-avformat --disable-avfilter \
        --disable-swscale --disable-swresample --enable-decoder=aac,mp3,alac,h264 --enable-encoder=aac --enable-static --disable-shared \
        --extra-cflags="-miphoneos-version-min=$MIN" >"$ROOT/logs/ffmpeg.log" 2>&1 \
  && make -j"$JOBS" >>"$ROOT/logs/ffmpeg.log" 2>&1 && make install >>"$ROOT/logs/ffmpeg.log" 2>&1)
echo "iOS dependencies ready: $P"
