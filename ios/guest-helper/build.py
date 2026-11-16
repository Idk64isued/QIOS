#!/usr/bin/env python3
"""Builds the guest helpers, static armv6 Mach-Os, and writes each into the app as Swift source.

    python3 ios/guest-helper/build.py          (needs clang with the ARM target)
    python3 ios/guest-helper/build.py --check  (fails if an app copy is not what its .S builds)

The programs are lt-mkdirs.S (folders and owners) and lt-unpack.S (a whole app bundle from one archive). Nothing links it: there is no libSystem to link against and no linker left that makes
32-bit iOS binaries, so this script lays out the executable itself, the way a static iPhone OS 1-3 binary looks:
__PAGEZERO, one __TEXT segment holding the header and the code, and LC_UNIXTHREAD pointing the PC at the code. The
kernel maps it and jumps in with sp at argc. iPhone OS 1 had no code signing; 2 and 3 run unsigned code with the
boot arguments every prepared device has (cs_enforcement_disable=1).

Output: ios/App/Sources/GuestHelperBinary.swift and GuestUnpackBinary.swift (base64), so the app needs no extra
resource.
"""
import base64
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(HERE, "..", "App", "Sources")

# (assembly, Swift file, enum, path in the guest, what it is)
HELPERS = [
    ("lt-mkdirs.S", "GuestHelperBinary.swift", "GuestHelperBinary", "/usr/local/bin/lt-mkdirs",
     "lt-mkdirs, a static armv6 program the app puts into the guest to make folders and set owners\n"
     "/// (`lt-mkdirs UID GID PATH...`), which a stock iPhone OS image has no tool for."),
    ("lt-unpack.S", "GuestUnpackBinary.swift", "GuestUnpackBinary", "/usr/local/bin/lt-unpack",
     "lt-unpack, a static armv6 program the app puts into the guest to write a whole app bundle from one archive\n"
     "/// (`lt-unpack UID GID ARCHIVE`, the archive GuestInstaller.Pack writes), instead of one agent request per file."),
]

CPU_TYPE_ARM, CPU_SUBTYPE_ARM_V6 = 12, 6
MH_MAGIC, MH_EXECUTE, MH_NOUNDEFS = 0xFEEDFACE, 2, 1
LC_SEGMENT, LC_UNIXTHREAD, ARM_THREAD_STATE, ARM_THREAD_STATE_COUNT = 0x1, 0x5, 1, 17
BASE = 0x1000


def text_bytes(source):
    with tempfile.TemporaryDirectory() as tmp:
        obj = os.path.join(tmp, "lt.o")
        subprocess.run(["clang", "-target", "armv6-apple-ios3.0", "-c", os.path.join(HERE, source), "-o", obj],
                       check=True)
        return section_text(open(obj, "rb").read())


def section_text(o):
    """__TEXT,__text out of a 32-bit Mach-O object. Its only relocations are branches within the section, which
    the assembler has already resolved (they stay right wherever the section lands)."""
    magic, cpu, _, _, ncmds, _, _ = struct.unpack_from("<IiiIIII", o, 0)
    assert magic == MH_MAGIC and cpu == CPU_TYPE_ARM, "not a 32-bit ARM Mach-O object"
    off = 28
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", o, off)
        if cmd == LC_SEGMENT:
            nsects = struct.unpack_from("<I", o, off + 48)[0]
            for i in range(nsects):
                s = off + 56 + 68 * i
                name, segname = o[s:s + 16].rstrip(b"\0"), o[s + 16:s + 32].rstrip(b"\0")
                _, sz, fo = struct.unpack_from("<III", o, s + 32)
                if name == b"__text" and segname == b"__TEXT":
                    return o[fo:fo + sz]
        off += size
    raise SystemExit("no __text section")


def seg(name, vmaddr, vmsize, fileoff, filesize, prot, sections=b"", nsects=0):
    return struct.pack("<II16sIIIIiiII", LC_SEGMENT, 56 + len(sections), name.encode(), vmaddr, vmsize, fileoff,
                       filesize, prot, prot, nsects, 0) + sections


def macho(code):
    header_size = 28
    pagezero = 56
    text_cmd = 56 + 68
    thread = 16 + 4 * ARM_THREAD_STATE_COUNT
    code_off = header_size + pagezero + text_cmd + thread
    assert code_off % 4 == 0
    total = code_off + len(code)
    entry = BASE + code_off
    section = struct.pack("<16s16sIIIIIIIII", b"__text", b"__TEXT", entry, len(code), code_off, 2, 0, 0,
                          0x80000400, 0, 0)
    cmds = seg("__PAGEZERO", 0, BASE, 0, 0, 0)
    cmds += seg("__TEXT", BASE, BASE, 0, total, 5, section, 1)
    regs = [0] * 13 + [0, 0, entry, 0x10]  # r0-r12, sp (the kernel sets it), lr, pc, cpsr (user mode, ARM state)
    cmds += struct.pack("<IIII", LC_UNIXTHREAD, thread, ARM_THREAD_STATE, ARM_THREAD_STATE_COUNT)
    cmds += struct.pack("<17I", *regs)
    header = struct.pack("<IiiIIII", MH_MAGIC, CPU_TYPE_ARM, CPU_SUBTYPE_ARM_V6, MH_EXECUTE, 3, len(cmds), MH_NOUNDEFS)
    blob = header + cmds + code
    assert len(blob) == total and total <= BASE
    return blob, entry


def embedded(path):
    import re
    current = open(path).read()
    return base64.b64decode("".join(re.findall(r'"([A-Za-z0-9+/=]+)"', current.split("data = Data(")[1])))


def main():
    stale = []
    for source, swift_name, enum, guest_path, doc in HELPERS:
        blob, _ = macho(text_bytes(source))
        out = os.path.join(SOURCES, swift_name)
        if "--check" in sys.argv:
            if not os.path.exists(out) or embedded(out) != blob:
                stale.append(os.path.relpath(out))
            else:
                print(f"guest helper: the app's copy matches {source}")
            continue
        if "--print" in sys.argv:
            sys.stdout.write(base64.b64encode(blob).decode() + "\n")
            continue
        b64 = base64.b64encode(blob).decode()
        lines = [b64[i:i + 100] for i in range(0, len(b64), 100)]
        swift = (
            f"// Generated by ios/guest-helper/build.py from {source}. Do not edit.\n"
            "import Foundation\n\n"
            f"/// {doc}\n"
            f"enum {enum} {{\n"
            f"    static let guestPath = \"{guest_path}\"\n"
            "    static let data = Data(base64Encoded: [\n"
            + ",\n".join(f'        "{l}"' for l in lines)
            + "\n    ].joined())!\n}\n"
        )
        open(out, "w").write(swift)
        print(f"wrote {os.path.relpath(out)} ({len(blob)} bytes)")
    if stale:
        sys.exit("stale: " + ", ".join(stale) + ": run python3 ios/guest-helper/build.py")


if __name__ == "__main__":
    main()
