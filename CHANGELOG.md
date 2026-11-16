# Changelog

Light Touch for iOS (QIOS), newest first. Each update is named for its commit. "Added", "Fixed" and "Removed" say
what changed for someone using the app; the patch numbers are the emulator changes in `ios/patches/qemu-ios`.

## Update 55 — (not yet named)

**Fixed**
- iOS 4 and 5: installed apps still showed a blank white icon after update 54 (iOS 6, whose apps had never been
  drawn, came through with real icons — the tell). SpringBoard keeps the icons it has drawn in cache files, and on
  a Retina device (the iPhone 4) those are the @2x files; the install deleted only the non-Retina names, so an
  icon once drawn blank stayed blank through every reinstall. All the names go now. Reinstall an app (any app —
  the Home screen redraws every icon) to get the real icons back.
- A white box with a stuck badge from installs made before update 52 (the old "Waiting…" placeholder, tagged by
  bundle ID) is now taken down when that app is installed again.
- An icon drawn as a solid black box, and apps whose graphics came out black or wrong on iOS 5 and 6: those draw
  through four graphics calls (vertex array objects) the emulator refused — the log said "the guest will render
  wrong", and it did. The emulator carries them now (patch 0020).

## Update 54 — (not yet named)

**Fixed**
- iOS 5 and 6: an installed app came up with a blank white icon (iOS 5) or never reached the Home screen at all
  (iOS 6), even though it was on the device and in the Apps list. These versions don't accept an app-list entry
  this app writes, however exactly it is shaped — update 53's sequence numbers, placeholders and cache clearing
  made no difference. Now, on 5 and 6, the install deletes the app list instead and lets iOS rebuild it from the
  apps on disk as the Home screen restarts, so iOS writes every entry itself. The install then waits and checks
  the rebuilt list names the app (the log says how it went); if no list reappears within half a minute, the old
  one is put back with the entry added the old way, so the device is never left without its apps. Apps already
  installed on an iOS 5 or 6 device are picked up by the same rebuild on the next install.
- iPhone OS 2 to iOS 4 installs are unchanged.

## Update 53

**Tried** (kept, but didn't cure it — see update 54)
- iOS 6: apps never showed on the Home screen. This update bumped the app list's change counter the way iOS's
  installer does; iOS 6 still didn't show them.
- iOS 5: installed apps showed a blank white icon. This update skipped the "Waiting…" placeholder on iOS 4 and
  later and cleared the Home screen's icon caches before restarting it, as uicache does; the icons stayed blank.

**Fixed**
- Sound out of step with the screen: the player used to slow itself down (86–92% speed in the logs) whenever the
  emulator fell behind, so the sound drifted behind the picture. It now stays in sync, with a moment of silence when
  the emulator can't keep up. **Smooth sound** (Settings) brings the old behavior back.

## Update 52

**Faster**
- Device setup runs on JIT all the way through. Only the first emulator a launch started could use JIT (the
  debugger blesses fast code once, then leaves), so the keybag and first-start boots of a setup, and the device
  you started after it, ran on the interpreter: iOS 5 on the iPhone 4 spent most of an hour in "Starting iOS". Now
  the app has the debugger bless one buffer when it opens, and every boot of that launch uses it (patch 0019).
- No more 15-minute stall at "Booting the restore ramdisk": that boot was waiting on a debugger iOS had paused in
  the background.

**Fixed**
- iOS 4: an installed app's icon came up blank. The "Waiting…" placeholder is now taken down before the Home
  screen restarts, instead of after it.
- Cool down automatically made iOS 4 laggy: a phone running an emulator reports "serious" heat within seconds, so
  it ran at 30 frames a second the whole time. It now waits for "critical" and cools until the phone is back to fair.

## Revolutionary (update 51)

**Added**
- iOS 4 opens text fields with the on-screen keyboard again (see Fixed). A keyboard connected to the phone still
  becomes the device's own USB keyboard from its first key, and is unplugged when it disconnects.
- **Cool down automatically** (Settings, on by default): when the phone gets hot, the device's screen drops to 30
  frames a second until it cools, then goes back to 60, without a restart (patch 0018).
- iOS 5 is ready to try on the iPhone 4, iPhone 3GS, iPod touch 3G and 4G and the iPad (all marked experimental).

**Fixed**
- iOS 4: no on-screen keyboard. The device booted with a USB keyboard plugged in, and iOS 4 hides its own keyboard
  while one is connected. Saved states from before this update are skipped once (they include that keyboard).
- iOS 4: a flash of solid green as an app opened. An empty video buffer was shown before anything was in it
  (patch 0018).
- Screen recording crashed the app on Retina devices (iPhone 4): frames queued up faster than the encoder took them
  until iOS ran out of memory, and a failed encoder brought the app down. Now at most two frames wait, and a failure
  says so instead of crashing.
- A saved state from before a device had its NOR is thrown away instead of restoring a blank one.
- Preparation boots (the keybag and seal boots) show their console in Console › Device while they run, and the
  log keeps their last lines, so a setup that stalls on "Booting the restore ramdisk" can be diagnosed.

**Faster and cooler**
- The A4 devices' screen no longer allocates a whole frame (2.4 MB on Retina) every time it refreshes (patch 0018).

## Keybag fix 2 (update 50)

**Fixed**
- iPhone 3GS microphone: recording read silence, because the port the device records through answered every read
  with zeros. It now carries this phone's microphone (patch 0017).
- A device's save from before it had its NOR could put a blank NOR back (the iPhone 4 boot loop after Keybag fix).

## Keybag fix (update 49)

**Fixed**
- **iOS 4 boots on the iPhone 4.** The device's NOR, which holds the encryption keys iOS 4's data protection made
  when the device was prepared, was never given to the emulator; iOS 4 couldn't load its keybag ("FATAL KEYBAG
  ERROR") and rebooted forever. Every device with a NOR now gets its own writable copy, as the Mac app does.

**Removed**
- The Springboard home screen. The iOS 6 list is the default; a phone that was set to Springboard switches to it.

## Colors Everywhere fix (update 48)

**Fixed**
- A build error in the Springboard banner.

## Colors Everywhere (update 47)

**Added**
- Home screen choice (Settings › Home Screen): the original list drawn as iOS 6's grouped tables (pinstripes, ON/OFF
  switches, glossy bars), or the original glass look. The iOS 6 look comes in light and dark.
- Add Device as a Setup Assistant: slide to set up, choose a device, choose its software, name it, watch it being
  set up, "Welcome to your iPod touch". iOS 6 style or glass style, to match the home screen.
- Version badges in the version lists, with a red BETA n or gold GM tag on developer seeds.
- The Legacy Store's **Downloads** tab: what is downloading, waiting and done; downloads keep going after the store
  closes; apps can be downloaded with no device running and installed later; Install Again without downloading.
- Console: the device's serial console (with Settings › Boot › Kernel console) and Light Touch's log, live.
- GPS: the iPhone 3GS's location follows this phone (Settings › Location).
- Console button on the glass home screen; a forced-on microphone switch (in the … menu) for testing.

**Faster**
- App installs: the whole app goes over as one archive and unpacks in the device (`lt-unpack`). Angry Birds: about
  3 minutes before, 17 seconds after.
- The NAND read cache (patch 0015): the iPhone 4's boot was spending most of its time waiting on storage.
- ANGLE renders into an IOSurface (patch 0016): no `glReadPixels` per frame.

## Tilt and sleep, Prep fix, Hotfix

**Fixed**
- Tilt direction (roll), smoother tilt and compass; the sleep overlay no longer shows before a device has booted.
- On-device firmware preparation built again (a Swift compiler crash in the FirmwareKit patch).
- Sharp pixels in Seamless view, the 3D model's sleep animation being cut off.

## Everything Changes. Again.

**Added**
- 3D devices (View › 3D), the startup chime, Cool mode, sharp pixels.
- Tilt on every board (patch 0012).

**Faster and cooler**
- Jump-cache generations (patch 0013), memory handed back after preparation boots (patch 0014), a Metal presenter.

## Peeled off

**Added**
- Orientation: the picture inside the device's screen follows the front app (or how the device is held), touches
  turned to match; ANGLE packaged as a framework (patch 0011).

## Faster Than oranges

**Added**
- Graphics renderers: ANGLE (Metal, the default), iPhone GL, Classic (patches 0009, 0010); the microphone
  (patch 0007).

## Update 35, Update 34

**Fixed**
- Freezes under heavy storage writes (the VIC watch, patch 0008); preparation boots in-process (`OneShotRunner`).
- Music and photo import, the install path.

## Hello Again (update 33)

**Added**
- The app's icon and logo. Music import, photos and videos into the device, screen recording, tweaks (Apple's hidden
  switches), the install placeholder icon, the microphone.
- Newer devices prepared on the phone (iPhone 3GS, iPod touch 3G and 4G, iPhone 4, iPad).
- Settings: Wi-Fi, hardware keyboard keys, debug port.

## Update 32 and earlier (updates 13–32)

- **32**: installing apps without a jailbreak (`lt-mkdirs`, the guest agent), closing the app safely, graphics on an
  iOS host, texture fixes (patch 0005).
- **30–31**: the build checks (`precheck.py`, `check-all.sh`) that catch mistakes before CI does.
- **29**: original-iPhone firmware advice, shutting a device down, sound.
- **27–28**: what the device is told and reports (battery, charger, vibration, motion).
- **24–26**: carrier, calls and messages; the USB bridge; fixes for blank screens and phones that wedge after boot.
- **17–22**: the USB stack (AFC, lockdown, install proxy), the startup tone, diagnostics, boot fixes.
- **13–15**: Add Device (ready-made iPod touch, firmware from the catalog, your own IPSW), the app icon, preparation.
