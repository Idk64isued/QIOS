<div align="center">

<img src="ios/App/Assets.xcassets/Logo.imageset/Logo.png" width="160" alt="Halcyon">

# Halcyon

**Forward thinking, legacy reborn.**

*Formerly Light Touch for iOS (QIOS)*

</div>

An old-iPhone emulator that runs on an iPhone. StikDebug JIT, LiveContainer, GitHub Actions.

Runs on a device. iOS 3 through 6 boot, install apps and play them; Where's My Water, Need for Speed, Crash Team
Racing and Super Monkey Ball render correctly. Still rough in places — see [ROADMAP.md](ROADMAP.md) for what 1.0
needs and what is deliberately left for later, and [CHANGELOG.md](CHANGELOG.md) for what each update changed.

## The name

This was *Light Touch on iOS*, then *QIOS*, through update 82. It is Halcyon now — its own name, for what has
become its own project. The lineage is not hidden and is not meant to be: it is built on and named after
samhenrigold's **LightTouchMac**, and the repository, bundle id and build artifacts still carry the old names
because changing those would break every existing install for nothing.

## On how this was built

[LightTouchMac](https://github.com/samhenrigold/LightTouchMac) — the emulator this is built on — is not AI-written.
It is samhenrigold's work, and the QEMU fork underneath it is the work of its own authors. None of that was touched
by a model beyond what the port required.

The iOS port is a different matter, and it is worth being straight about it: the code under `ios/` was written with
AI, directed and tested by a person on a real iPhone over eighty-odd updates. Every patch in
`ios/patches/qemu-ios` was written that way too. What the port is and what it is for were decided by a human; the
typing largely was not.

Nothing here is a claim to have written the emulator. It is a claim to have gotten it onto a phone.

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
