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
