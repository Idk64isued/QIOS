#!/usr/bin/env python3
"""Builds the guest helpers, static armv6 Mach-Os, and writes each into the app as Swift source.

    python3 ios/guest-helper/build.py          (needs clang with the ARM target)
    python3 ios/guest-helper/build.py --check  (fails if an app copy is not what its .S builds)

The programs are lt-mkdirs.S (folders and owners), lt-unpack.S (a whole app bundle from one archive) and lt-install.S
(an .ipa to installd, the one that dyld loads: see macho_dyld). Nothing links them: there is no libSystem to link against and no linker left that makes
32-bit iOS binaries, so this script lays out the executable itself, the way a static iPhone OS 1-3 binary looks:
__PAGEZERO, one __TEXT segment holding the header and the code, and LC_UNIXTHREAD pointing the PC at the code. The
kernel maps it and jumps in with sp at argc. iPhone OS 1 had no code signing; 2 and 3 run unsigned code with the
boot arguments every prepared device has (cs_enforcement_disable=1).

Output: ios/App/Sources/GuestHelperBinary.swift and GuestUnpackBinary.swift (base64), so the app needs no extra
resource.
"""
import base64
import os
import re
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
    ("lt-install.S", "GuestInstallBinary.swift", "GuestInstallBinary", "/usr/local/bin/lt-install",
     "lt-install, an armv6 program the app puts into the guest to hand an .ipa to the device's own installer\n"
     "/// (`lt-install IPA`: MobileInstallationInstall, which installd answers). Dynamically linked: see macho_dyld."),
    ("lt-notify.S", "GuestNotifyBinary.swift", "GuestNotifyBinary", "/usr/local/bin/lt-notify",
     "lt-notify, an armv6 program the app puts into the guest to post Darwin notifications (`lt-notify NAME...`),\n"
     "/// the way installd does once it has installed something, so the rest of the system re-reads the app list.\n"
     "/// Dynamically linked: see macho_dyld."),
    ("lt-locate.S", "GuestLocateBinary.swift", "GuestLocateBinary", "/usr/local/bin/lt-locate",
     "lt-locate, an armv6 program the app puts into the guest to set where the device is (`lt-locate LAT LON`, or\n"
     "/// `lt-locate stop`) through CoreLocation's simulation interface, as Xcode does with a real phone. Dynamically\n"
     "/// linked and signed with com.apple.locationd.simulation: see macho_dyld and code_signature."),
]

# The helpers dyld loads, and the libSystem symbols bound into their __DATA, in slot order.
DYLD_HELPERS = {"lt-install.S": ["_dlopen", "_dlsym"], "lt-notify.S": ["_dlopen", "_dlsym"],
                "lt-locate.S": ["_dlopen", "_dlsym"]}

# Helpers that need entitlements, and which. locationd takes simulated locations only from a process signed with
# com.apple.locationd.simulation (Xcode's DTSimulateLocation is); the other two are what location-faking tools ask for
# alongside it, harmless where unused.
ENTITLED = {"lt-locate.S": ["com.apple.locationd.simulation", "com.apple.locationd.preauthorized",
                            "com.apple.locationd.effective_bundle"]}

CPU_TYPE_ARM, CPU_SUBTYPE_ARM_V6 = 12, 6
MH_MAGIC, MH_EXECUTE, MH_NOUNDEFS, MH_DYLDLINK, MH_TWOLEVEL = 0xFEEDFACE, 2, 1, 4, 0x80
LC_SEGMENT, LC_UNIXTHREAD, ARM_THREAD_STATE, ARM_THREAD_STATE_COUNT = 0x1, 0x5, 1, 17
LC_SYMTAB, LC_DYSYMTAB, LC_LOAD_DYLIB, LC_LOAD_DYLINKER, LC_DYLD_INFO_ONLY = 0x2, 0xB, 0xC, 0xE, 0x80000022
LC_CODE_SIGNATURE = 0x1D
BASE = 0x1000
PAGE = 0x1000
# Where macho_dyld puts __DATA. lt-install.S addresses it directly (mov r11, #0x2000).
DYLD_DATA = 0x2000


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


def lc_str(cmd, fixed, text):
    """A load command whose fixed part is followed by a NUL-terminated string, padded to a word."""
    raw = text.encode() + b"\0"
    raw += b"\0" * (-len(raw) % 4)
    return struct.pack("<II", cmd, 8 + len(fixed) + len(raw)) + fixed + raw


def uleb(n):
    out = bytearray()
    while True:
        byte, n = n & 0x7F, n >> 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def bind_opcodes(symbols, segment_index):
    """dyld's compressed binding for `symbols`, one pointer each from offset 0 of segment `segment_index`, all from
    the first library (libSystem). DO_BIND advances by a pointer, so consecutive symbols land in consecutive slots."""
    ops = bytearray([0x11, 0x51, 0x70 | segment_index]) + uleb(0)  # dylib 1, type pointer, segment + offset 0
    for name in symbols:
        ops += b"\x40" + name.encode() + b"\0"                      # SET_SYMBOL_TRAILING_FLAGS_IMM(0)
        ops += b"\x90"                                              # DO_BIND
    ops += b"\x00"                                                  # DONE
    ops += b"\0" * (-len(ops) % 4)
    return bytes(ops)


def entitlements_plist(keys):
    body = "".join(f"\t<key>{k}</key>\n\t<true/>\n" for k in keys)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n' + body + '</dict>\n</plist>\n').encode()


def code_signature(image, identifier, entitlements):
    """An ad-hoc code signature for `image` (the file up to where the signature goes), as ldid -S makes one: a
    SuperBlob holding a CodeDirectory (SHA-1 of every 4 KiB page, and of the entitlements and requirements blobs in
    their special slots), an empty requirements set and the entitlements. Nothing vouches for it -- there is no CMS
    signature -- and nothing needs to: every prepared device boots with signature enforcement off ("AMFI: Invalid
    signature but permitting execution"), and the kernel still reads the entitlements out of the blob, which is how
    locationd learns this process may simulate locations."""
    import hashlib
    sha1 = lambda b: hashlib.sha1(b).digest()
    ents = struct.pack(">II", 0xFADE7171, 8 + len(entitlements)) + entitlements
    reqs = struct.pack(">III", 0xFADE0C01, 12, 0)
    ident = identifier.encode() + b"\0"
    pages = [image[i:i + PAGE] for i in range(0, len(image), PAGE)]
    special = [b"\0" * 20] * 5                                       # slots -5 .. -1
    special[0] = sha1(ents)                                          # -5 entitlements
    special[3] = sha1(reqs)                                          # -2 requirements
    hashes = b"".join(special) + b"".join(sha1(p) for p in pages)
    header_len = 44
    ident_off = header_len
    hash_off = ident_off + len(ident) + 5 * 20
    cd_len = hash_off + 20 * len(pages)
    cd = struct.pack(">IIIIIIIIIBBBBI", 0xFADE0C02, cd_len, 0x20001, 0, hash_off, ident_off, 5, len(pages), len(image),
                     20, 1, 0, 12, 0)
    assert len(cd) == header_len
    cd += ident + hashes
    blobs = [(0, cd), (2, reqs), (5, ents)]
    off = 12 + 8 * len(blobs)
    index, payload = b"", b""
    for kind, blob in blobs:
        index += struct.pack(">II", kind, off + len(payload))
        payload += blob
    sb = struct.pack(">III", 0xFADE0CC0, 12 + len(index) + len(payload), len(blobs)) + index + payload
    return sb + b"\0" * (-len(sb) % 16)


def signature_size(image_len, identifier, entitlements):
    """The signature's length for an image this long, known before the image is (its header names it)."""
    return len(code_signature(b"\0" * image_len, identifier, entitlements))


def macho_dyld(code, symbols, entitlements=None, identifier=None):
    """A dynamically linked executable, laid out as ld would for iPhone OS 3-6 without a PIE flag:

        __PAGEZERO 0x0      __TEXT 0x1000 (header, load commands, code)
        __DATA 0x2000 (one pointer per symbol, then scratch the code uses)   __LINKEDIT 0x3000 (bind opcodes)

    LC_LOAD_DYLINKER makes the kernel start dyld, which binds `symbols` from libSystem into __DATA (LC_DYLD_INFO_ONLY
    binding, which dyld has read since 3.1: the stock MBXGLEngine uses it), then jumps to the LC_UNIXTHREAD pc with sp
    at argc, as for a static program. LC_SYMTAB and LC_DYSYMTAB are there and empty because dyld refuses an image
    without them. No code signature: every prepared device boots with cs_enforcement_disable=1."""
    linkedit = bind_opcodes(symbols, 2)
    strtab_off = len(linkedit)
    linkedit += b"\0" * 4                                            # the string table: "" (and padding)
    if entitlements is not None:
        linkedit += b"\0" * (-len(linkedit) % 16)                     # a signature after it starts 16-aligned
    text_vm, data_vm, link_vm = BASE, DYLD_DATA, DYLD_DATA + PAGE
    data_off, link_off = PAGE, 2 * PAGE
    sig_off = link_off + len(linkedit)
    sig_len = signature_size(sig_off, identifier, entitlements) if entitlements is not None else 0

    def build(code_off):
        entry = text_vm + code_off
        section = struct.pack("<16s16sIIIIIIIII", b"__text", b"__TEXT", entry, len(code), code_off, 2, 0, 0,
                              0x80000400, 0, 0)
        cmds = seg("__PAGEZERO", 0, BASE, 0, 0, 0)
        cmds += seg("__TEXT", text_vm, PAGE, 0, PAGE, 5, section, 1)
        # One ordinary section over the slots: dyld binds by segment and offset either way, but a segment with no
        # sections is one tools (and some loaders) skip when they number segments for binding.
        data_section = struct.pack("<16s16sIIIIIIIII", b"__data", b"__DATA", data_vm, 64, data_off, 2, 0, 0, 0, 0, 0)
        cmds += seg("__DATA", data_vm, PAGE, data_off, PAGE, 3, data_section, 1)
        cmds += seg("__LINKEDIT", link_vm, PAGE, link_off, len(linkedit) + sig_len, 1)
        cmds += struct.pack("<12I", LC_DYLD_INFO_ONLY, 48, 0, 0, link_off, strtab_off, 0, 0, 0, 0, 0, 0)
        cmds += struct.pack("<6I", LC_SYMTAB, 24, link_off + strtab_off, 0, link_off + strtab_off, 4)
        cmds += struct.pack("<II18I", LC_DYSYMTAB, 80, *([0] * 18))
        cmds += lc_str(LC_LOAD_DYLINKER, struct.pack("<I", 12), "/usr/lib/dyld")
        # name at 24, timestamp 2, current 1.0.0, compatibility 1.0.0 (every libSystem since 1.0 is >= that)
        cmds += lc_str(LC_LOAD_DYLIB, struct.pack("<IIII", 24, 2, 0x10000, 0x10000), "/usr/lib/libSystem.B.dylib")
        regs = [0] * 13 + [0, 0, entry, 0x10]
        cmds += struct.pack("<IIII", LC_UNIXTHREAD, 16 + 4 * ARM_THREAD_STATE_COUNT, ARM_THREAD_STATE,
                            ARM_THREAD_STATE_COUNT) + struct.pack("<17I", *regs)
        ncmds = 10
        if sig_len:
            cmds += struct.pack("<IIII", LC_CODE_SIGNATURE, 16, sig_off, sig_len)
            ncmds += 1
        header = struct.pack("<IiiIIII", MH_MAGIC, CPU_TYPE_ARM, CPU_SUBTYPE_ARM_V6, MH_EXECUTE, ncmds, len(cmds),
                             MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL)
        return header, cmds, entry

    header, cmds, _ = build(0)
    code_off = len(header) + len(cmds)
    header, cmds, entry = build(code_off)
    assert len(header) + len(cmds) == code_off and code_off % 4 == 0
    text = header + cmds + code
    assert len(text) <= PAGE, "lt-install's code no longer fits its one page of __TEXT"
    blob = text + b"\0" * (PAGE - len(text)) + b"\0" * PAGE + linkedit
    if sig_len:
        assert len(blob) == sig_off
        signature = code_signature(blob, identifier, entitlements)
        assert len(signature) == sig_len
        blob += signature
    return blob, entry


def embedded(path):
    import re
    current = open(path).read()
    return base64.b64decode("".join(re.findall(r'"([A-Za-z0-9+/=]+)"', current.split("data = Data(")[1])))


def check_path_file():
    """lt-install.S and GuestInstaller.swift both spell out the file lt-install reads when argv is empty. One is
    assembly and one is Swift, so nothing but this makes them agree, and disagreeing would put the install back
    where update 69 found it: lt-install reporting a failure the app reads as installd's refusal."""
    with open(os.path.join(HERE, "lt-install.S"), encoding="utf-8") as f:
        asm = re.findall(r'\.asciz\s+"(/var/mobile/[^"]*lt-install\.path)"', f.read())
    with open(os.path.join(SOURCES, "GuestInstaller.swift"), encoding="utf-8") as f:
        swift = f.read()
    staging = re.search(r'installStaging\s*=\s*"([^"]+)"', swift)
    tail = re.search(r'installPathFile\s*=\s*installStaging\s*\+\s*"([^"]+)"', swift)
    if len(asm) != 1 or not staging or not tail:
        return "lt-install's path file could not be found in both lt-install.S and GuestInstaller.swift"
    if asm[0] != staging.group(1) + tail.group(1):
        return f"lt-install.S reads {asm[0]} but the app writes {staging.group(1) + tail.group(1)}"
    print(f"guest helper: lt-install.S and the app agree on {asm[0]}")
    return None


def main():
    stale = []
    for source, swift_name, enum, guest_path, doc in HELPERS:
        if source in DYLD_HELPERS:
            ents = entitlements_plist(ENTITLED[source]) if source in ENTITLED else None
            blob, _ = macho_dyld(text_bytes(source), DYLD_HELPERS[source], ents, source[:-2])
        else:
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
    if "--check" in sys.argv:
        if (problem := check_path_file()) is not None:
            stale.append(problem)
    if stale:
        sys.exit("stale: " + ", ".join(stale) + ": run python3 ios/guest-helper/build.py")


if __name__ == "__main__":
    main()
