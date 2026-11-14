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
