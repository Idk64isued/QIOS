# Changelog

Light Touch for iOS (QIOS), newest first. Each update is named for its commit. "Added", "Fixed" and "Removed" say
what changed for someone using the app; the patch numbers are the emulator changes in `ios/patches/qemu-ios`.

## Update 61 — Cydia Oh My Cydia

**Fixed**
- **The internet works properly.** Every prepared device is baked with a proxy auto-config that sends its web traffic
  to `PROXY 10.0.2.100:3128; DIRECT` — on the Mac that is a real helper process running beside the emulator, and this
  app, which runs the emulator as a library inside itself, has never had one. Nothing answered that address, so
  CFNetwork tried it first on *every single connection*, waited out the connect timeout, and only then fell back to
  going direct, with nothing remembered between attempts. That is the whole of "it says it's connected but everything
  times out": Cydia taking minutes to list a repository and then timing out on an install, the store spinning, a web
  page taking a minute. The traffic was never broken — it was queued behind a dead proxy. Light Touch now rewrites
  that PAC to go straight out, on every boot, on devices old and new. The original is kept, and Tweaks ▸ Put Back the
  Web Proxy restores it for anyone running a proxy of their own. (This does not give the device modern encryption: a
  site needing TLS 1.2 and a recent root still won't load. Cydia's repositories are plain HTTP and are fine.)
- **iOS 6 installs apps again, and stops boot-looping afterwards.** From iOS 4 up the installer took the app list
  away and let MobileInstallation rebuild it from the app folders as the Home screen restarted — the jailbreak-era
  "delete the plist" trick. The order was fatal: the list went, SpringBoard was restarted, and only *then* did the
  install wait half a minute to see whether a rebuild had happened. On iOS 6 it doesn't ("No rebuilt app list after
  30 seconds" in the log), so SpringBoard came up with no app list at all, fell over, was restarted by launchd, and
  fell over again. Putting the old list back thirty seconds later was far too late. The entry is now written before
  the restart and the list is never taken away, so there is no window in which the device has none. The icons were
  never the list's doing anyway — copying the app's icon to `Icon.png` and `Icon@2x.png`, the names every one of
  these iOS versions actually looks for, is what fixed those, and that runs either way.
- **Copying anything is several times faster** — songs, photos, an app bundle. The guest's agent sleeps a quarter of
  a second whenever it looks for work and finds none. Sending one 252 KiB chunk, waiting for its reply and only then
  sending the next meant its queue was empty every time it looked, so each chunk cost its own transfer *plus* most of
  that sleep: about a megabyte a second, whatever the link underneath could do. A few chunks are now kept queued
  ahead, so it never sleeps in the middle of a file. The log no longer carries a line per chunk either.
- An install that installd turns down no longer copies the whole `.ipa` in first on every later app that session —
  that upload was half the time a big install took, spent on a refusal that cannot change within a boot. The log also
  prints what installd actually said now, instead of guessing "no AppSync" at every kind of failure.
- **This phone's volume buttons are this phone's again.** Sending them to the device was novel and then just in the
  way: you couldn't turn the sound down while a device was open, and the device threw its own volume overlay up over
  whatever was running. It is now Settings ▸ Volume buttons, off by default.

**Changed**
- **The graphics front end inside iOS 6 devices is replaced with the one from LightTouchMac v1.0-2026.11.16**, and
  patch 0023 teaches this emulator to speak to it. The older one can't read iOS 6's longer dispatch stubs: of 6.1.3's
  914 entry points it named 309 and left 605 unknown, so calls as basic as the framebuffer and viewport ones went
  nowhere. That is why games drew into the wrong place or not at all — Need for Speed Shift in a small box in the
  corner, Shrek Kart and Monkey Ball sideways over garbage, FIFA and Goat Z falling over on launch, Minecraft black.
  The new one reads them all. It goes in automatically on 6.x and later; 1.x–5.x devices are untouched. The old file
  is kept, and Tweaks ▸ Put Back the Old GL restores it (and opts that device out) if anything draws worse.
- **Settings is readable.** Every switch used to carry a full paragraph under it — twenty-odd of them, so the page was
  a wall of grey text you had to read through to find the line you came for. Each row now shows its name and a few
  words; the full explanation is behind the ⓘ beside it. The ones most people never touch — the boot log, the debug
  port, the USB bridge, the translation cache — start collapsed under Advanced.
- **The Legacy Store has a dark mode**, on its own switch (the moon in its top bar), independent of this phone's
  appearance. Same bar glosses, borders and pinstripes, different material; the light side is unchanged to the hex
  digit.
- **The Setup Assistant is full screen under the iOS 6 interface.** It was always drawn as iOS 6's, but it arrived as
  a modern sheet — a rounded card stopping short of the top with the Home screen behind it — which was the one thing
  giving it away. The glass interface still gets a sheet.
- Settings ▸ Location now says what it can and can't do: only the iPhone 3GS has a GPS receiver the modem answers, so
  on every other board there is nothing for iOS to ask and Location Services finds nothing however it is set.
- **Updates are called by their names where the work happens.** The build reads this file's newest heading and puts
  it at the top of the run's summary in Actions, so a run says "Update 61 — Cydia Oh My Cydia" rather than only a
  number, and stamps it into the app so the first line of every log carries it too (`build 1.0-abc1234 (63), Update
  61 — Cydia Oh My Cydia`). A run started by hand, which has no commit to be named after, says so and names the
  branch. Name an update in its commit message and the Actions list reads as the changelog does.

## Update 60 — (not yet named)

**Changed**
- iOS 4 and up install apps the way the Mac app and iTunes do: through the device's own installer, installd. Every
  earlier fix wrote the app in by hand — its folders, its files, its entry in the app list (or the list rebuilt from
  disk) — and on iOS 4 and 5 the icon stayed blank through all of them, with the icon files present, readable and
  uncached and the app list written by iOS itself. Upstream's own documentation says it never does any of that: "User
  applications are installed after boot by native MobileInstallation", with AppSync baked into installd at
  preparation so unsigned apps are accepted — which every iOS 4-capable device here already has (its recipe's
  `appsync: true`); nothing had ever asked installd to do anything. Now the .ipa is copied in and a new guest helper,
  `lt-install`, calls `MobileInstallationInstall`, the call jailbreak-era `ipainstaller` made. installd unpacks,
  places and registers the app and tells SpringBoard, which draws the icon as it does any other app's — no respring.
  If installd won't take an app, the log says why (`lt-install: N`) and the install falls back to the old path, so
  nothing that installed before stops installing. iPhone OS 1 to 3 keep the old path, which always worked there.
  - `lt-install` is the first guest helper that dyld loads (it needs CoreFoundation and MobileInstallation). It is
    laid out by hand like the others, and its test plays dyld under the ARM emulator: binds its symbols from the
    opcodes the way dyld does, fakes the three libraries, and checks the call, its arguments and the result line.

**Merged**
- LightTouchMac as of today (upstream 668b1fe1, from 2f170060 of Nov 5): 247 files, mostly the Mac app and the iPhone
  5 (iOS 10.3.4, which this app doesn't offer: preparing one needs the Mac). On the phone it brings
  the iPhone 5's device art and FirmwareKit's newer preparation code; nothing in this app's own behaviour changes.
  Checked before shipping: no public API the app uses was removed or changed (two gained a defaulted parameter), the
  HostRuntime patch and the FirmwareKit iOS patch still apply, and every check passes on the merged tree.
- **The iOS emulator keeps its own pin** (`ios/qemu-ios.json`, still 1ad1c781). Upstream moved the Mac's emulator to
  db230fe8e8, and 9 of the 22 iOS emulator patches no longer apply there; following it would have broken the build.
  Moving it — which would also bring upstream's faster TCG engine work — is its own job: rebase those 9, then move
  the pin and the Mac files release together.
- The Prepare device workflow (the Mac preparer on a GitHub runner) builds its guest tools from the iOS emulator's pin
  too. Upstream's newer emulator speaks a different GL name table (0xf31a2b68 against this emulator's 0xad3b3412), so a
  device prepared with it would have carried a graphics library this app's emulator doesn't match. Not run since the
  merge: if `scripts/vendor` refuses the older pin, that workflow fails at its Vendor step and says so.
- The build's caches are now keyed on the nine dependencies the iOS build actually uses, not the Mac app's whole list,
  so a merge that only adds a Mac package (this one added TelemetryDeck) doesn't rebuild ANGLE and the emulator. The
  change of key itself costs one full rebuild, this once.

## Update 59 — (not yet named)

**Fixed**
- The blank white icon on iOS 4, with the guesswork finally cut out of it. Update 58's diagnostics ruled out every
  cause the last four updates aimed at: the bundle declares `Icon.png`, both `Icon.png` and `Icon@2x.png` are in
  the guest at full size, and the device has no SpringBoard icon cache that could have gone stale — and a
  period-correct build of the app drew the blank tile anyway. An icon that is present, readable and uncached and
  still doesn't draw is not an icon problem: it is an app iOS never properly registered, which is exactly what
  iOS 5 and 6 turned out to be doing. The hand-written app-list entry is enough to get a name onto the Home screen
  and not enough to get an icon drawn. So iOS 4 now registers the way 5 and 6 do: the app list is taken away and
  MobileInstallation rebuilds it from the apps on disk, in the shape iOS wants. If the rebuild doesn't come, the
  old list goes back with the entry written by hand, as before, so a device is never left without its apps.

**Added**
- Names the GL entry points the dispatch table loses on iOS 6 and 7, where OpenGLES gives the bridge no names to
  read and it has to recognise each call by decoding its code — 309 of 914 against all 905 on iOS 5, and every one
  it misses is a call it refuses. Each failure is now counted by reason and named, and the calls that build a
  render target are checked by name, since one of those missing is enough on its own to explain Minecraft's black
  screen (patch 0022).

## Update 58 — Family Fun

**Added**
- What's New: the changelog is in the app now, on the main menu, and it opens by itself once after an update, so
  a new build says what it changed instead of landing silently.

**Fixed**
- The blank white icon on iOS 4 and 5, and for a reason the last four updates all missed: it was never the icon
  cache. The apps that came through with real icons are old ones that ship `Icon.png`; the ones that stayed blank
  are modern builds whose icon is declared under `CFBundleIcons` (iOS 5 and up), named for an asset catalog, or
  kept only inside `Assets.car` — which no iOS this old can read at all. SpringBoard went looking for `Icon.png`,
  found nothing, and drew the blank tile. Every app now gets an icon under that classic name: the one the bundle
  declares if it is there as a file, else the largest icon-looking image left loose in the bundle, else the
  artwork the App Store wrapped the .ipa in. A bundle that already has `Icon.png` keeps its own.
- Importing a batch of photos or songs no longer sits on one item looking stuck. Each item was copying the
  importer tool into the device all over again and deleting it afterwards — an upload and two round trips per
  item, on top of the item itself. The tool goes over once per boot now, and the copy shows its percentage, so a
  slow item reads as busy rather than frozen.
- Location says something useful when it can't start. Inside LiveContainer, iOS grants location to LiveContainer
  itself, so a missing permission there came back as a flat "not allowed" that read like a refusal in this app's
  own settings. The log now names the app the permission actually belongs to, and tells a refusal apart from a
  LiveContainer build that has no location at all.

**Known, not fixed here**
- Minecraft draws nothing on iOS 6, and the log is now specific about why: it draws into a framebuffer with no
  attachment (`0x8CD7`), so every draw is thrown away and the screen stays black. The likely cause is the gap
  already on the list — on iOS 6 the GL bridge can name only 309 of 914 entry points, against all 905 on iOS 5,
  so the call that attaches the render target is probably one of the 605 it cannot name and drops. Naming
  iOS 6's table is its own piece of work, and it is next.

## Update 57 — (not yet named)

**Fixed**
- Two fingers now reach the emulated device, so pinch to zoom, rotate and two-finger scroll work. The app has
  always tracked a second finger and sent it; the emulator dropped everything but the first, and every gesture
  arrived in the guest as a one-finger drag (patch 0021).

**Added**
- The install log now says what icon the app's Info.plist declares, which of those files actually reached the
  guest, and which of SpringBoard's icon caches were really there to clear. The blank icon on iOS 4 and 5 has
  survived three fixes aimed at the cache; these three lines say whether the cache was ever the problem.

## Update 56 — (not yet named)

**Added**
- The log's first lines now name the build that wrote it (`build 1.0-<commit> (<run number>)`), stamped in by CI.
  Update 55's graphics fix was investigated as if it had never shipped, on the strength of a log that turned out to
  predate the install; a log can no longer be mistaken for one from a different build.

**Fixed**
- iOS 5: the white icon came back on the next install, after update 55's icon-cache fix had worked once. Two causes,
  both fixed here. SpringBoard keeps the same icon cache in memory that it keeps in those files, so deleting the
  files while it was running bought nothing — it wrote its copy straight back. The caches are now deleted with
  SpringBoard held down (`launchctl unload`, delete, `load`), so the Home screen that comes back has nothing cached
  and draws every icon from the app bundles. If it can't hold SpringBoard down it says so and clears them anyway,
  the way it used to.
- Reinstalling an app made a second copy of it instead of replacing it: the install looked for the app's existing
  container under a key (`Container`) that the lists iOS 5 and 6 write themselves don't always carry, so it minted
  a new container and left two bundles with the same bundle ID on disk. It now takes the container from the entry's
  `Path` as well, and a reinstall lands where the app already lives, documents and settings included.
  - A device that already has a duplicate from before this fix keeps it: the app list points at one of the two
    bundles and the other is invisible junk. Recreating that device is the clean way out.

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
