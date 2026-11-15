# Light Touch on iOS: getting a device onto the phone

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
