# Light Touch

Built with use from agentic coding products.

Light Touch runs classic Apple devices on your Mac: the original iPhone and iPod touch through the
iPhone 4, iPod touch 4 and the first iPad, on the iPhone OS and iOS versions they shipped with. Each
device runs Apple's own firmware in an emulator, so it behaves like the real thing: the Home screen,
the built-in apps, App Store apps and games of the era, Wi-Fi, music and photos, and on the iPhones a
simulated cellular network for calls and texts.

## Download

Get the latest notarized build from [Releases](https://github.com/samhenrigold/LightTouchMac/releases),
unzip it, and move **Light Touch.app** to Applications.

- macOS 14.4 or later, on Apple silicon or Intel.
- Light Touch includes a ready-to-use iPod touch (2nd gen) on iOS 3.1.3. For every other device and
  version it downloads Apple's original firmware (from Apple, or from public archives for builds Apple
  no longer hosts), checks it against its published hash, and prepares the device on your Mac. You can
  also import an IPSW you already have.

## Devices

| Device | Versions |
|---|---|
| iPhone | iPhone OS 1.0 |
| iPhone 3GS | iPhone OS 3.0 to iOS 6.1.6 |
| iPhone 4 (GSM) | iOS 4.0 to 7.1.2, plus iOS 6.0 and 7.0 betas |
| iPod touch (1st gen) | iPhone OS 1.1 to 1.1.5 |
| iPod touch (2nd gen) | iPhone OS 2.1.1 to iOS 4.2.1 |
| iPod touch (3rd gen) | iPhone OS 3.1.1 to iOS 5.1.1 |
| iPod touch (4th gen) | iOS 4.1 to 6.1.6, plus the iOS 6.0 beta |
| iPad | iPhone OS 3.2 to iOS 5.1.1 |

Most builds are marked experimental: they boot and pass their checks, but haven't been through as much
use as the stable ones. Turn on **Show experimental** in the Add Device sheet to see them.

## Scope

Light Touch is a Mac app for the devices in the table above, and that's all it will be. These aren't
planned, and requests for them will be closed:

- Versions for Windows, Linux, Android, iOS, iPadOS or the web, including companion or remote apps.
- Other devices: iPod classic, nano or shuffle, Apple TV, Apple Watch, or any iPhone, iPod touch or
  iPad newer than the ones listed.
- iOS versions those devices never ran.

Bug reports and ideas for the listed devices on the Mac are welcome.

## Building from source

See [CONTRIBUTING.md](CONTRIBUTING.md). The tests come in three tiers:

```sh
# no emulator: the packages' Swift Testing suites
xcodebuild test -project LightTouchMac.xcodeproj -scheme LightTouchMac -testPlan Unit
# emulator sessions, headless and silent, on a prepared device (sessions --help lists the checks)
swift run --package-path tests/sessions sessions single PREPARED_BASE
# a built app: signatures, bundle, closure and the built-in iPod's boot
TEST_RUNNER_LTM_RELEASE_APP="path/to/Light Touch.app" xcodebuild test -project LightTouchMac.xcodeproj \
    -scheme LightTouchMac -testPlan Release
```

## License and credits

Light Touch is free software under the GNU General Public License, version 2 or (at your option) any
later version; see [LICENSE](LICENSE).

It stands on a lot of other work:

- [qemu-ios](https://github.com/samhenrigold/qemu-ios), the emulator, built on [QEMU](https://www.qemu.org)
  and grown out of [devos50's qemu-ios](https://github.com/devos50/qemu-ios) (GPL-2.0).
- [libimobiledevice](https://libimobiledevice.org), libusbmuxd, libplist, libtatsu and a
  [usbmuxd fork](https://github.com/samhenrigold/usbmuxd) for talking to the devices.
- iBoot32Patcher, FFmpeg, GLib, libslirp, PCRE2, pixman, OpenSSL, and Unrar.swift with RARLAB's UnRAR.

Each bundled component's license (and, for GPL and LGPL components, where to get its source) is in
the app under `Contents/Resources/licenses` and in **About Light Touch**.

iPhone, iPod touch and iPad are trademarks of Apple Inc. Light Touch is not affiliated with Apple.
