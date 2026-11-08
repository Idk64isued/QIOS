#!/usr/bin/env python3
"""Unpack a Light Touch packed device (an .itbase folder) into a device base, on any OS.

The Mac app ships a ready iPod touch 2G (iOS 3.1.3) as Contents/Resources/Device/n72ap-7E18.itbase. This does what
`firmwarekit unpack-base` does for the files themselves (PreparedBase.unpack in FirmwareKit), checking every sha256:

    python3 unpack_itbase.py "/path/to/Light Touch.app/Contents/Resources/Device/n72ap-7E18.itbase" OUT/Devices/iPod-touch-2G

It writes OUT/Devices/iPod-touch-2G/base/ (device.lock.json inside), the layout the iOS app lists. Not done here:
the unit identity reseed and the language seed. The packed base was built in en-US with the identity it was packed with,
which boots; a reseed only gives each install its own serial/UDID.

Format (FirmwareKit PreparedBase): index.json {format 2, chunkBytes 1 MiB, files[{name,size,mode,sha256}],
images[{name,size,mode,chunks{"000123": sha256 of the raw 1 MiB}}]}; files/<name> whole; <image minus extension>/<NNNNNN>.z
zlib-compressed chunk N; a chunk with no file is all zero.
"""
import hashlib
import json
import os
import sys
import zlib

CHUNK = 1 << 20


def fail(message):
    sys.exit(f"unpack_itbase: {message}")


def safe(name):
    parts = name.split("/")
    if not name or name.startswith("/") or any(p in ("", ".", "..") for p in parts):
        fail(f"refusing entry name {name!r}")
    return name


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def unpack(itbase, base):
    try:
        index = json.load(open(os.path.join(itbase, "index.json")))
    except (OSError, ValueError):
        fail(f"{itbase} has no readable index.json (is this an .itbase folder?)")
    if index.get("format") != 2 or index.get("chunkBytes") != CHUNK:
        fail(f"unsupported packed-device format {index.get('format')} / chunk {index.get('chunkBytes')}")
    os.makedirs(base, exist_ok=True)
    total = len(index["files"]) + sum(len(i["chunks"]) for i in index["images"])
    done = 0

    def tick():
        nonlocal done
        done += 1
        if done % 200 == 0 or done == total:
            print(f"\r  {done}/{total}", end="", flush=True)

    for f in index["files"]:
        name = safe(f["name"])
        data = open(os.path.join(itbase, "files", name), "rb").read()
        if len(data) != f["size"] or sha256(data) != f["sha256"]:
            fail(f"{name} differs from its index")
        out = os.path.join(base, name)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as h:
            h.write(data)
        os.chmod(out, f["mode"] | 0o200)  # keep it writable here; the app works on a copy in overlay/
        tick()

    for image in index["images"]:
        name = safe(image["name"])
        out = os.path.join(base, name)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        stem = os.path.splitext(name)[0]
        with open(out, "wb") as h:
            h.truncate(image["size"])  # holes stay sparse and read as zero
            for number, want in sorted(image["chunks"].items()):
                i = int(number)
                if i < 0 or i * CHUNK >= image["size"]:
                    fail(f"{name} chunk {number} is outside the image")
                packed = open(os.path.join(itbase, stem, f"{number}.z"), "rb").read()
                raw = zlib.decompress(packed)
                if len(raw) != min(CHUNK, image["size"] - i * CHUNK) or sha256(raw) != want:
                    fail(f"{name} chunk {number} is damaged")
                h.seek(i * CHUNK)
                h.write(raw)
                tick()
        os.chmod(out, image["mode"] | 0o200)
    print()
    if not os.path.exists(os.path.join(base, "device.lock.json")):
        fail("unpacked, but there is no device.lock.json: wrong or incomplete packed device")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    itbase, device = sys.argv[1], sys.argv[2]
    base = os.path.join(device, "base")
    if os.path.exists(base):
        fail(f"{base} already exists; remove it or pick another folder")
    print(f"unpacking {itbase} -> {base}")
    unpack(itbase, base)
    print(f"done. Copy {device} to the phone: Files > On My iPhone > Light Touch > Devices")


if __name__ == "__main__":
    main()
