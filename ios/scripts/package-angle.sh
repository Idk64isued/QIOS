#!/bin/bash
# Put ANGLE (build-angle-ios.sh's output) into the app's Frameworks the way ANGLE's iOS libEGL looks for it:
# libEGL.dylib, and libGLESv2 as libGLESv2.framework/libGLESv2 beside it (libEGL opens exactly that path; the
# emulator opens the same file, so both get one image). Re-signs what it changes.
#     package-angle.sh ANGLE_OUT APP_FRAMEWORKS_DIR
set -euo pipefail
A="${1:?usage: package-angle.sh angle-out frameworks-dir}"
F="${2:?usage: package-angle.sh angle-out frameworks-dir}"
mkdir -p "$F/libGLESv2.framework"
cp "$A/libEGL.dylib" "$F/libEGL.dylib"
cp "$A/libGLESv2.dylib" "$F/libGLESv2.framework/libGLESv2"
chmod 755 "$F/libEGL.dylib" "$F/libGLESv2.framework/libGLESv2"
install_name_tool -id "@rpath/libGLESv2.framework/libGLESv2" "$F/libGLESv2.framework/libGLESv2"
# libEGL linking libGLESv2 by name (rather than opening it): point the link at the framework too.
old="$(otool -L "$F/libEGL.dylib" | awk '/libGLESv2/ {print $1; exit}')"
if [ -n "$old" ] && [ "$old" != "@rpath/libGLESv2.framework/libGLESv2" ]; then
    install_name_tool -change "$old" "@rpath/libGLESv2.framework/libGLESv2" "$F/libEGL.dylib"
fi
cat > "$F/libGLESv2.framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>libGLESv2</string>
  <key>CFBundleIdentifier</key><string>dev.lighttouch.angle.libGLESv2</string>
  <key>CFBundleName</key><string>libGLESv2</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>16.0</string>
</dict></plist>
PLIST
codesign -f -s - "$F/libEGL.dylib"
codesign -f -s - "$F/libGLESv2.framework"
echo "ANGLE: $F/libEGL.dylib, $F/libGLESv2.framework/libGLESv2"
