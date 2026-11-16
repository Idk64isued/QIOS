# Light Touch on iOS: getting a device onto the phone

What changed in each update: [CHANGELOG.md](../CHANGELOG.md).

Everything can be done on the phone now. Enable JIT first (StikDebug, script `universal.js`; in LiveContainer use
Launch with JIT), open Light Touch, then tap **Add Device**.

## Add Device

- **Ready-made iPod touch** (iPhone OS 3.1.3): the device the Mac app starts with. The app downloads the Mac release
  (about 390 MB, once), takes the boot ROMs and the packed iPod out of it, and unpacks it. Nothing to prepare.
- **From firmware**: pick a model and a version from the Mac app's own catalog. The app downloads the IPSW (checked
  against the catalog's SHA-1), then prepares the device on the phone with FirmwareKit, the Mac app's preparer, running
  in-process with its offline disk code (`--hfs writer`). Works for the iPod touch 2G up to 3.1.3 and the iPhone OS 1
  devices; anything that needs a preparation boot (iOS 4 data protection, the iPad, the A4 devices) still has to be
  prepared in the Mac app and copied over.
- **Your own IPSW**: pick the file; it is matched to the catalog by its SHA-1.

Add Device is a Setup Assistant: slide to set up, choose a device, choose its software, name it and pick its options,
watch it being set up, then "Welcome to your iPod touch" with Start Using. It is iOS 6's look with the iOS 6 list home
screen, and the glass look (gradient, frosted cards, system switches) with the glass one.
Each version in the lists carries a badge: its major version on a tile in that version's own colours (Light Touch's
design, not Apple's artwork), with a red BETA n or a gold GM tag on a developer seed (the catalog's `prerelease`).

## Home screen (Settings › Home Screen)

- **Original (iOS 6)** (the default): the original home screen, section for section (status, devices, library,
  settings, log), drawn as iOS 6's grouped tables on pinstripes with its ON/OFF switches.
- **Original (Glass)**: the original look, with a Console button in its Log card.

The iOS 6 look comes in light and dark (Settings › Appearance, or the phone's own setting). iOS 6 never had a
dark mode; this one is what it would have been: the black glossy bars of its media apps, slate pinstripes, charcoal
cells, the same blue for what's chosen. Its Settings screen (the list's Settings button) holds the home screen and appearance choices, the settings the original home screen
carries, All Settings, and the log.

The Mac files come from the release named in `MacFiles.releaseTag` (FirmwareLibrary.swift). It has to be the release
built from the same sources as this repository's emulator (`build-support/sources.json`): the guest's graphics library
and the emulator speak a versioned protocol. Change the tag together with an upstream sync.

## Where things are

| In Files > LightTouch | What |
| --- | --- |
| `Devices/<name>/base` | a prepared device (read-only); `overlay` beside it is what the device has written since |
| `Device/` | boot ROMs (`bootrom_240_4`, `ipod1g/bootrom_s5l8900`) and packed devices (`*.itbase`) |
| `IPSW/<catalog id>.ipsw` | downloaded or imported firmware |
| `lighttouch.log`, `prepare.log` | the last boot's log and the last preparation's log |

**Storage** (on the home screen) shows what each of these takes and removes what you no longer want.

Copying by hand still works: a prepared device's `base/` folder into `Devices/<name>/base`, or the Mac app's
`Contents/Resources/Device` folder into `Device/`.

## Builds

CI builds the app twice if it has to: with FirmwareKit (after `ios/scripts/patch-firmwarekit.py` makes it compile for
iOS), and, if that fails, without it. The run's summary says which one the IPA is; the fallback can do everything
except prepare firmware. The `build-logs` artifact has the compiler's errors.

On a PC you can also unpack a packed device with `ios/tools/unpack_itbase.py` (a copied NAND image loses its holes
and gets big, so unpacking on the phone is better).

## Which original-iPhone firmware to use

On the original iPhone, **iPhone OS 1.0 runs well** — calls, texts, the carrier and the clipboard all work there.
**1.1.x reaches the Home screen and then locks up** (the interrupt rate climbs into the hundreds of thousands a second
and the frame rate falls to zero), with the modem on or off. The firmware catalog lists those builds as *untested*
upstream; until the emulator itself is fixed for them, 1.0 is the one to make.

## Shutting a device down

**Save & quit** or **Shut down properly** from the controls. Both leave the device able to start again.

Closing the app while a device is running does not. Its storage is only consistent once iOS on the device has
finished its own shutdown, so a device that lost power mid-write spends its next boot repairing its filesystem —
and on hardware emulated this slowly, that repair takes longer than anyone will wait. It looks exactly like a
device that will no longer start.

If one is in that state, hold its row on the home screen and choose **Erase content**. That returns it to how it
was prepared, without building the whole device again. (The same thing lives in Storage.)

## What the device can be told, and what it reports

The emulator exposes the same set of host calls the Mac app drives, and the app now uses them:

* **Rotation.** The device's framebuffer is portrait, always — a real iPhone's panel doesn't turn, you do, and iOS
  draws its interface sideways inside it. So the app sets the device's orientation outright (UIDeviceOrientation:
  portrait, upside down, Home right, Home left) and turns the *picture* to match, shell and all. Setting it
  outright rather than stepping it is what makes the direction reliable. Touches still land: the display maps them
  in its own unturned coordinates, which are the framebuffer's.
* **Shake**, and a **second finger** — a pinch lands on the device's own screen rather than zooming this app's view
  of it.
* **This phone stands in for the hardware**: its battery shows in the old status bar, a charger is reported (which
  is also what stops iOS idle-sleeping), tilting this phone tilts the device and its compass follows, and when the
  device buzzes this phone buzzes.
* **The clipboard** goes both ways.
* **The device's own answers**: whether it has turned its screen off (the screen goes dark with a slow drift of
  z's, and a tap wakes it — so a sleeping device doesn't look like a wedged one), whether its storage has stopped
  answering, and whether it has shut itself down.
* **Pause and resume**: the emulated CPU stops while the app is in the background instead of quietly draining
  this phone in a pocket.
* **Restart and power off** properly, rather than pulling the plug.
* **Network policy**: restrict the device to this app's services, or let it see the local network.

All of it is optional at run time: an older emulator library simply lacks a call, and the app does without it.

Anything you set once lives in **Settings** (the gear on the controls). The menu beside it holds only things you do
in the moment. Settings also has **Appearance** — System, Light or Dark. The device's own stage stays dark either
way.

Not used: the keyboard calls. On the iPod touch 2G the guest agent types faster than tapping the on-screen keyboard
would, and the 1.x boards have nothing on the other end of a keyboard at all.

## Sound

The device's sound arrives at the pace the emulator manages, which on a slow board (the iPod touch 1G with software
graphics) is in bursts. The player keeps a small jitter buffer — it waits until it holds ~120 ms before playing,
waits again when it runs dry rather than stuttering, fades at both edges, and trims itself back if it falls more
than half a second behind — so a slow device sounds gappy rather than corrupted.

## Carrier, calls and messages

The emulated iPhones carry a fake cellular baseband, and the emulator lets the app set its properties by name. The
gear menu's **Carrier** screen (phones only — an iPod touch has no modem) uses that for:

* the operator name in the status bar and the signal strength, applied straight away rather than at the next reboot;
* **calling**: ring the device from a number you choose, have the caller pick up, or hang up on it;
* **texting**: deliver a message from a number, which arrives in Messages as a real one would.

The modem refuses to ring or deliver anything until the guest is registered on the network, so if the status line at
the top of that screen says "no service", give it a moment after boot and try again.

## When a screen comes out blank

A device's screen is drawn by translating the guest's OpenGL ES to this phone's. Where that translation falls short
the geometry is still right but the contents are not, and the usual symptom is **blank white boxes** where icons,
text and images should be — iPhone OS 1 does this on some builds, and the log says so in as many words
(`DRAWING INTO INCOMPLETE framebuffer … this draw produces nothing`).

**Software graphics** in the Add Device wizard prepares the device with that translation left out
(FirmwareKit's `gles_shim` off), so the device composites its own screen the way it did on the real hardware. It is
slower, and it is the thing to try when a device boots but draws nothing worth looking at.

## When a phone boots and then wedges

The iPhones carry a fake modem on UART1 that the iPod touch does not have. If a phone reaches the Home screen and
then locks up a few seconds later — the log shows the interrupt rate climbing into the hundreds of thousands a
second and the frame rate falling to zero — turn **Cellular modem** off in the gear menu and boot again. That
passes `baseband=off` to the machine and leaves that serial line empty.

If it boots and stays up with the modem off, the modem is what wedges it (and calls and texts are off with it). If
it wedges anyway, the modem is innocent and the next suspect is the Bluetooth line, which has no switch yet.

## The USB bridge

Off by default; **Settings → USB bridge** turns it on for the next boot.

The emulator carries a USB device controller and talks to a host over a TCP socket
(`qemu-ios docs/tcp-usb-protocol.md`). When no host is configured the emulator runs one in-process, which is why a
device boots perfectly well with the bridge off. Passing `usb-tcp-addr` switches that built-in host **off**, so with
the bridge on this app owes the guest everything a host does, for the whole session:

* `ios/App/Sources/USB/TCPUSB.swift` — the socket and the 5-byte framing. The emulator dials in (and redials on every
  USB core soft reset), so the newest connection wins and a dropped link is retryable rather than fatal.
* `USBDevice.swift` — enumeration by hand: reset, enumeration-done, descriptors, SET_ADDRESS, SET_CONFIGURATION of
  the configuration carrying the mux interface, Apple's vendor power request (what makes iOS report external power
  and stop idle-sleeping), then the string descriptors. Deliberately the same sequence the built-in host runs.
* `USBMuxClient.swift` — usbmux as the device speaks it: the version handshake, then real TCP segments per service.
* `USBHostBridge.swift` — one thread that enumerates, keeps polling the bulk IN endpoint (the guest's mux restarts the
  whole stack if the host goes quiet) and starts over every few seconds for as long as the device runs. A guest needs
  about 100 seconds of boot before its USB core answers at all, and every transaction is NAKed until then; that is
  normal and not a failure.

**Ask the device over USB** in the gear menu opens lockdown and asks who it is, which exercises the whole path.
Services like AFC and installation_proxy are gated behind a pairing record, which this bridge cannot make yet, so an
IPA install over USB works only where the device hands them out unauthenticated; otherwise the guest agent does it.

If the device does not come up over USB on two boots in a row the bridge turns itself off, so a setting can never
leave a device unbootable.

## Installing apps (no jailbreak)

Apps install through the guest agent, which runs as root inside the device. A stock image has no tool to make a
folder, so the app puts one in: `lt-mkdirs` (ios/guest-helper), a 456-byte static armv6 program, built from
`lt-mkdirs.S` by `build.py` and embedded in `GuestHelperBinary.swift`; `test.py` runs it under an ARM emulator. On
iPhone OS 2 and 3 the app goes into a container in /var/mobile/Applications owned by mobile and is added to
MobileInstallation's cache; on iPhone OS 1 it goes into /Applications. SpringBoard then restarts and shows it. The
Apps list reads the same cache, so it works without a jailbreak too.

## Closing the app

With "Survive closing the app" on (Settings, on by default), going to the background saves the device, and a swipe
away from the app switcher no longer loses it: the next start picks up from there ("Picks up where it left off" on its
row). Coming back without being closed just carries on. A device drawing with hardware graphics (3.x) can't be saved
on this host yet; it gets its storage flushed instead, so it always starts again cleanly.

## Graphics on an iOS host

Apple's GL on the phone enforces rules the Mac's doesn't, and each one cost whole textures (the white icon boxes):
`ios/patches/qemu-ios/0005-ios-es-texture-rules.patch` gives non-power-of-two textures the clamp and no-mipmap state
iOS needs, makes a texture's internal format match its data, and drops the ES 3.0-only row-length setting. The
console shows `[gles] npot texture ...` for each texture it fixed and `[gles] REFUSED ...` for anything the bridge
still turns down; send those lines when something draws wrong.

## Music

Menu › Add music: songs from Files or from this phone's own music library (bought or added songs; Apple Music
songs are protected) go into the device's Music app with their tags and covers. The song is staged in
/var/mobile/Media/LightTouch/<id>/ and the Mac app's guest helper `itmedia` (in the guest tools this app already
downloads) adds it through iOS's own MusicLibrary. iPhone OS 3.1 and later.

## Newer devices (prepared on the phone)

The iPhone 3GS, iPod touch 3G, iPod touch 4G, iPhone 4 and iPad (and the iPod touch 2G on iOS 4) need one or more
preparation boots: a keybag boot for iOS 4 data protection, and a seal boot that runs the device once until it halts
cleanly. The Mac app runs these in a helper process. iOS starts no processes, and QEMU only starts once per loaded
library, so here each boot loads its own copy of the emulator library (a copied file is a fresh image under the same
signature), runs headless on a thread, and is left behind when it ends (`OneShotRunner.swift`, FirmwareKit's
`InProcessOneShot` hook added by `patch-firmwarekit.py`). Each copy's guest RAM is handed back when its boot ends
(`qemu_ios_release_guest_memory`, `patches/qemu-ios/0014`); the rest it holds stays taken until the app quits, so
restart Light Touch after preparing one of these before starting it. The iPad is prepared with its kboot chain
(iBoot32Patcher, which its iBoot chain needs, is a Mac tool).

The keybag boot runs the firmware's own restore ramdisk with `it_keybag` put into it. Restore ramdisks are
case-insensitive HFS+, which the Mac edits through hdiutil and diskutil; on the phone `patch-firmwarekit.py` lets
HFSPlusWriter edit them, ordering their catalog case-folded as HFS+ does (`BTreeFile.foldedCatalogOrder`). The
preparation boots' time limits are three times the Mac's (eight on the interpreter).

For the iPhone 4, the builds marked experimental that need no second IPSW are 4.0 (8A293), 4.1 (8B117), 4.2.1
(8C148) and 4.3 (8F190). 4.3.1 to 4.3.5 take their keybag ramdisk from 4.3's IPSW (a sibling), which the phone
can't download alongside yet.

## Speed and heat

- `patches/qemu-ios/0013`: the jump cache (guest address to translated code, 16K entries per address space) is
  emptied by bumping a generation instead of clearing every entry. Guests invalidate position-independent
  translations hundreds of times a second while code loads (an app starting, a game loading), and each one emptied
  every vCPU's cache; that was 12% of the main loop in a 3GS log. A self-modifying-code test runs 2.3x faster with
  it, and code that doesn't modify itself runs the same.
- `build-qemu.sh` configures with `--disable-qom-cast-debug`: QEMU otherwise checks every QOM cast (each device
  register access casts its device) by looking the type up.
- `patches/qemu-ios/0015`: a read cache in the NAND image layer. Each emulated flash read is a blocking `blk_pread`
  that parks the virtual CPU until it completes, and an iOS 4 boot does a huge number of them (data protection
  decrypts the system a page at a time), so the guest spends most of a boot stalled on storage while the host sits
  idle. A hit serves the page from RAM. It is read-only data — a write updates its own slot and an erase drops the
  block's slots, so it can never hand back stale or lost data. `IT_NAND_CACHE` sets the slot count (default 8192,
  about 17 MB for an A4's records; 0 turns it off). With diagnostics on, the log prints the hit rate now and then.
- `patches/qemu-ios/0016`: the ANGLE renderer's frame buffer on an IOSurface (EGL_ANGLE_iosurface_client_buffer), as
  the EAGL renderer's already was. On Metal the texture the guest draws into is the IOSurface's own memory, so each
  present copies out of a mapped page instead of a `glReadPixels`, which on the phone's tile-based GPU was a full
  pipeline drain plus a second copy every frame. If ANGLE lacks the extension or binds IOSurfaces to a rectangle
  target (macOS), it keeps the readback; the log says which (`[gles-angle] frame buffer on an IOSurface`).
- `patches/qemu-ios/0017`: the iPhone 3GS's microphone. Its I2S port's FIFO window (0x84500000, the DT's i2s0 reg,
  which the CDMA uses both ways) answered every read with 0, so capture was silence and the app never saw the guest
  listening. A read there is now the RX FIFO, fed by the phone's microphone; the log names the offset the guest's
  capture channel reads (`s5l8930-i2s: capture reads the FIFO window at +0x…`).
- `patches/qemu-ios/0018`: the panel's frame rate changes while the device runs (`qemu_ios_ui_set_refresh_hz`, the
  displays' `live-refresh-hz`), which AutoCool uses to drop to 30 Hz while the phone is hot. A video layer whose
  chroma plane is all zeros (a buffer nothing has written yet) is left out instead of shown as solid green, the
  flash iOS 4 put up as an app opened. The A4 display allocates its video buffer only while video is on.
- `patches/qemu-ios/0019`: one JIT code buffer per launch. Under TXM only the attached debugger can make pages
  executable, and QEMU tells it to detach once it has, so only the first QEMU in a launch got JIT: a preparation's
  keybag, seal and check boots (each a fresh copy of the library) and the device after them ran on the
  interpreter, and a seal boot took most of an hour. A bless asked for long after launch could also wait forever on
  a debugger iOS had suspended (an iOS 5 keybag boot sat 910 s silent). Now the app blesses one buffer as it starts
  (`qemu_ios_jit_pool_create`, named in `QEMU_IOS_JIT_POOL`) and every QEMU it starts after takes it.
- The screen is drawn through Metal (`MetalPresenter`): one copy of each frame into a shared texture and a blit,
  instead of a CGImage per frame that Core Animation copied and converted again.
- The profiler samples 10 times a second (it was 50; every sample stops the virtual CPU for a moment).
- Settings › Cool mode runs the guest's screen at 30 Hz (`refresh-hz` on both LCD models) and the display at 30 fps:
  about half the drawing and readback work. Games that count frames instead of time run slower in it.
- Settings › Sharp pixels (on by default): nearest-neighbour scaling, so the device's pixels are crisp squares.

## 3D devices (View › 3D)

The Mac app's models (`Models/*.usdz`, bundled as a folder) through RealityKit (`Model3D.swift`, a port of the Mac's
`DeviceModelView`): the live screen is a material on the model's display, and touches on it go to the guest by
casting a ray onto the panel. Elsewhere, drag turns the device, two fingers bring it closer, and a double tap
stands it back up; its Home and Sleep/Wake buttons work. Device › Special trick is the Mac's kickflip with its
chime. Models ship for the iPod touch 1G, 2G, 3G (the 2G's) and 4G, the iPhone 3GS and the iPad; the iPhone and
iPhone 4 show With Device. Needs iOS 18. A still model is swapped for a snapshot after half a second, as on the Mac,
so it costs nothing while nothing moves.

## Freezes under heavy storage writes (VIC watch)

Reports from the iPod touch 2G showed the device stopping for minutes during big installs: the emulated CPU idle in
WFI, nothing drawn, the agent timing out, then recovering by itself. `patches/qemu-ios/0008` watches the interrupt
controllers (PL192): an enabled interrupt held back for two seconds while the CPU sits idle means the controller's
priority stack lost a pop, and the watch logs a `[vic] … held back` line with its state and clears the stale
priority. `IT_VIC_WATCH=log` only logs; `IT_VIC_WATCH=0` turns it off. If freezes continue without `[vic]` lines,
the cause is elsewhere.

## Graphics renderers (Settings › Graphics)

- **ANGLE** (default): CI builds Google's ANGLE for iOS (`scripts/build-angle-ios.sh`, Metal only, cached per pinned
  commit) and ships `libEGL.dylib` and `libGLESv2.framework` beside the emulator (`scripts/package-angle.sh`:
  ANGLE's iOS libEGL opens libGLESv2 at that framework path, so the emulator opens the same file, patch 0011).
  qemu-ios's ANGLE renderer (the Mac's experimental one) is built beside the EAGL one (`patches/qemu-ios/0009`) and
  chosen per boot with `-M …,gl-renderer=angle`: ES 1.1 and ES 2.0 guests both draw on Metal.
- **iPhone GL** (test): the same adapter over the phone's own OpenGL ES, an ES 1.1 context for ES 1.1 guests and an
  ES 3.0 one for ES 2.0 guests (`patches/qemu-ios/0010`, `gl-renderer=es3`). EAGL contexts of different APIs can't
  share objects, so they don't.
- **Classic**: the first renderer, OpenGL ES 1.1 only (it carries the iPod touch 2G texture fixes, 0004–0006). The
  S5L8920 and A4 devices (shaders) are prepared with `ca_ogl` off under it, and draw in software.

If ANGLE fails to build, CI says so in a warning and the build ships with Classic only.

## Orientation

The device's frame never turns; the picture inside its screen does (`DisplayUIView.turns`, set from
`DeviceControls.quarterTurns`), and touches are turned back before they reach the guest. Where the guest agent
reports how the front app stands (3.1.3), the picture follows it continuously: a landscape app reads upright, the
portrait-only Home screen stays upright however the device is held. Elsewhere it follows how the device is held (the
menu's Rotate, or this phone's tilt with Tilt and compass on). In immersive mode the screen's frame also goes wide
for a sideways picture. A turn picked from the menu holds until the guest's own orientation changes; Upright hands
the picture back to the guest. With Tilt and compass on the menu's turns do nothing: the picture stays lined up with
this phone (Light Touch's own interface turns to landscape with it), so a guest that rotates when tilted reads upright.

## Tilt and compass

CoreMotion's gravity vector (not its Euler pitch and roll, which read an upright phone as flat) becomes the
emulator's attitude in its flat pose (`DeviceControls.guestAttitude`), so the device's accelerometer reads what this
phone's does. The iPod and A4 machines take it through their `accel-pitch`/`-roll`/`-pose` properties; the S5L8920
boards (iPhone 3GS, iPod touch 3G) have none, so `patches/qemu-ios/0012` hands it straight to their LIS302DL. Boards
with a gyro see each change as a turn. The heading goes to `compass-heading` where the board has a compass.

## Microphone

On the S5L8920 and A4 machines (iPhone 3GS, iPod touch 3G and 4G, iPhone 4, iPad), with Settings › Microphone on,
the phone's microphone turns on by itself while the device records and off three seconds after; it feeds this phone's microphone into the codec's I2S capture (`patches/qemu-ios/0007`): converted
to 44.1 kHz, doubled to stereo, read by the guest when it records. The iPod touch 2G and the 1.x boards have no
capture path in their I2S models, so the item isn't offered there.

## Photos, videos, recording, tweaks

- **Add photos & videos**: a photo becomes an upright baseline JPEG (≤ 2048 px) that the guest's `itphoto` saves
  into Saved Photos; a video becomes H.264 + AAC (640×480 Baseline, or 720p Main on the A4 boards) that `itmedia`
  adds to Videos. iPhone OS 3.1 or later.
- **Record the screen**: every frame the guest draws and the sound it makes, into an .mp4 saved to Photos.
- **Tweaks**: Apple's hidden switches (Signal as Numbers, Keynote Clock, Slow Animations, Emoji Everywhere, Safari
  debugging) written as the mobile user's preferences, plus Core Animation's debug colors through the agent.
- **Install placeholder**: an app being installed shows SpringBoard's own "Waiting…" icon (the agent's `dlicon`).

## Settings added in update 33

- **Wi-Fi**: the device's Wi-Fi card on QEMU's user network (slirp). Plain HTTP works; HTTPS sites that refuse
  old TLS don't, because the Mac app's TLS-upgrading web proxy and its certificate trust aren't ported yet.
- **Hardware keyboard keys**: on the boards with a USB host the emulator attaches a USB keyboard and gets raw keys.
- **Debug port**: QEMU's gdbstub on TCP 1234, for one boot. It has no password; leave it off otherwise.

## Reports

Files › LightTouch › Reports keeps the last ten sessions' logs (saved when the next session starts, so a crash or a
swipe-away loses nothing) and every report made. Menu › Send report packs a zip (what happened, device, phone,
settings, the log and the last session's, the screen, compatibility notes) for the share sheet, or copies a short
summary. The log also carries `[prof]` lines every 15 seconds: where the emulator's CPU thread spends its time, with
addresses in libqemu-arm.dylib that `qemu-symbols.txt` (in the build-logs artifact) turns into function names.

## Legacy Store

Full screen, laid out like iPhone OS 3's App Store, on Legacy Store's open API: Featured (apps for this device, and
the site's collections), Top 50 (any chart type, as it stood on any archived day; arrows step between days),
Categories and Search. Each app's page has its archived screenshots (by version), star rating, description,
information, reviews and every archived version. "Report" on an app's page records how it ran (kept on this phone,
shown in the lists, put into reports, and postable as a GitHub issue; Legacy Store's API takes no submissions).

**Downloads** (the fifth tab, with a red badge while anything is going): what is downloading or installing, what is
waiting its turn, and what came down before. Getting several apps queues them, one download at a time, and closing
the store doesn't stop them. With no device running, apps are just downloaded; INSTALL on a downloaded app puts it on
whichever device is running later, and INSTALL AGAIN reinstalls one without fetching it again. The IPAs are kept in the
Downloads cache (the system may clear it when the phone is short of space); Clear, or holding a row and Remove,
deletes them. The list survives relaunches.

## How a build is checked

1. **Before a push** (any computer with Python, no Mac needed): `bash ios/scripts/check-all.sh`. It parses every
   Swift file and checks calls into the app's own types (members that don't exist, properties called like functions,
   wrong argument labels, methods that hide system calls like `send`, Int32 values from the emulator stored as Int,
   APIs newer than iOS 16), plus the plist, project specs, workflow and shell scripts. Needs
   `pip install tree-sitter==0.26.1 tree-sitter-swift==0.7.4 pyyaml`.
2. **precheck job** (Linux, ~30 s): the same Swift check, then `precheck-selftest.py`, which re-injects every mistake
   that has broken a real build and fails if the checker stops catching one. The macOS build waits for it.
3. **build job** (macOS): the app first (~5 min), with every error reported in one pass, shown on the commit's lines,
   in the run summary and in `errors.txt` inside build-logs. Errors only in `ios/App/Sources` stop the run there
   instead of retrying without firmware preparation. The emulator libraries come from cache unless something that
   goes into them changed (qemu-ios pin, patches, build scripts, Xcode), so a code-only change no longer rebuilds
   QEMU. A newer push cancels the older run.

When a CI failure gets past the precheck, add it as a case in `precheck-selftest.py` with the fix.
