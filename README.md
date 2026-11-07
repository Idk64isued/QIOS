# Light Touch on iOS (StikDebug JIT, LiveContainer, GitHub Actions)

Untested port. Nothing here has been compiled or run on a device; expect to fix things from the first CI logs.

## Install into your fork
Run `import.sh` inside a clone of this repo (see the top of the script): it adds the LightTouchMac source plus `ios/` and `.github/`. Keep the repository **private**; the upstream README is kept as `UPSTREAM-README.md`.

## 1. Build the app (Actions > "iOS build" > Run workflow)
Produces `LightTouch.ipa` (unsigned, with `libqemu-arm.dylib` JIT build and `libqemu-arm-tci.dylib` fallback inside).
It applies `ios/patches/0001-hostruntime-ios.patch` (HostRuntime for iOS) and
`ios/patches/qemu-ios/0001-ios-universal-jit.patch` (JIT through StikDebug's current script protocol).
If a step fails, the logs are uploaded as `build-logs`; the glib/FFmpeg cross-builds are the likeliest to need tweaks.

## 2. Prepare a device (Actions > "Prepare device")
Pick a catalog id (e.g. `n72ap-7E18` = iPod touch 2G, iOS 3.1.3). The workflow runs the Mac app's own preparer on a
macOS runner and uploads `package/Devices/<id>/base`. Needs Xcode 27 on the runner (currently a public preview) and
the SecureROM files `scripts/vendor` asks for; if it stops, its message says what is missing. Never publish the result.

## 3. Install and run
1. Sideload `LightTouch.ipa` (SideStore/Sideloadly) or add it to LiveContainer.
2. Unzip the device artifact; in Files copy `Devices/<id>` to **LightTouch > Devices**, and the boot ROMs to
   **LightTouch > Device** (`bootrom_240_4`, `ipod1g/bootrom_s5l8900`). Pull to refresh in the app.
3. Enable JIT before launching: StikDebug attaches to Light Touch (or to LiveContainer, via its "Launch with JIT").
   On iOS 26 TXM devices (A15/M2 and later) choose the **universal.js** script; the app asks the debugger to bless its
   code buffer and then detaches. The app screen shows whether JIT was seen; without it the slow interpreter loads.
4. Tap the device. QEMU can start once per launch: after shutting down, reopen the app.

## Not in this version
Wi-Fi/web proxy, USB bridge and app install, on-device firmware preparation, rotation, second finger. Sound is wired up
(`AudioPlayer.swift`) but unverified.
