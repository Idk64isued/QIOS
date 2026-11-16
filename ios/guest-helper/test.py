#!/usr/bin/env python3
"""Runs the guest helpers under an ARM emulator (unicorn) with a kernel-style stack and checks what they do:
lt-mkdirs by the system calls it makes, lt-unpack by the files it leaves in a small in-memory filesystem.

    pip install unicorn && python3 ios/guest-helper/test.py
"""
import base64
import re
import struct
import sys
import os

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_INTR, UcError
from unicorn.arm_const import UC_ARM_REG_SP, UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R12, \
    UC_ARM_REG_PC

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    src = open(os.path.join(HERE, "..", "App", "Sources", name)).read()
    return base64.b64decode("".join(re.findall(r'"([A-Za-z0-9+/=]+)"', src.split("data = Data(")[1])))


blob = load("GuestHelperBinary.swift")
unpack_blob = load("GuestUnpackBinary.swift")


def run(args):
    uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
    uc.mem_map(0x1000, 0x1000)
    uc.mem_write(0x1000, blob)                      # __TEXT: fileoff 0 at vmaddr 0x1000
    entry = struct.unpack_from("<I", blob, 28 + 56 + 124 + 16 + 15 * 4)[0]
    stack, strings = 0x80000, 0x90000
    uc.mem_map(stack - 0x10000, 0x30000)              # the stack page and the argument strings above it
    ptrs, at = [], strings
    for a in args:
        uc.mem_write(at, a.encode() + b"\0")
        ptrs.append(at)
        at += len(a) + 1
    frame = struct.pack(f"<I{len(ptrs)}III", len(ptrs), *ptrs, 0, 0)   # argc, argv..., NULL, envp NULL
    uc.mem_write(stack, frame)
    uc.reg_write(UC_ARM_REG_SP, stack)
    calls = []

    def cstr(addr):
        out = b""
        while True:
            c = uc.mem_read(addr, 1)
            if c == b"\0":
                return out.decode()
            out += bytes(c)
            addr += 1

    def svc(uc, intno, _):
        n = uc.reg_read(UC_ARM_REG_R12)
        r0, r1, r2 = (uc.reg_read(r) for r in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2))
        if n == 136:
            calls.append(("mkdir", cstr(r0), oct(r1)))
        elif n == 16:
            calls.append(("chown", cstr(r0), r1, r2))
        elif n == 1:
            calls.append(("exit", r0))
            uc.emu_stop()
        else:
            calls.append(("?", n))
            uc.emu_stop()
        uc.reg_write(UC_ARM_REG_R0, 0)

    uc.hook_add(UC_HOOK_INTR, svc)
    uc.emu_start(entry, 0x2000, count=10000)
    return calls


def check(args, want):
    got = run(args)
    ok = got == want
    print(("ok   " if ok else "FAIL ") + " ".join(args))
    if not ok:
        print("  got ", got, "\n  want", want)
    return ok


good = all([
    check(["/usr/local/bin/lt-mkdirs", "501", "501", "/var/mobile/Applications/X", "/var/mobile/Applications/X/A.app"],
          [("mkdir", "/var/mobile/Applications/X", "0o755"), ("chown", "/var/mobile/Applications/X", 501, 501),
           ("mkdir", "/var/mobile/Applications/X/A.app", "0o755"), ("chown", "/var/mobile/Applications/X/A.app", 501, 501),
           ("exit", 0)]),
    check(["/usr/local/bin/lt-mkdirs", "0", "80", "/Applications/B.app"],
          [("mkdir", "/Applications/B.app", "0o755"), ("chown", "/Applications/B.app", 0, 80), ("exit", 0)]),
    check(["/usr/local/bin/lt-mkdirs", "501"], [("exit", 0)]),
    check(["/usr/local/bin/lt-mkdirs"], [("exit", 0)]),
])


# ---- lt-unpack: a tiny kernel with an in-memory filesystem ----

def pack(items):
    """The archive GuestInstaller.Pack writes: ("dir", path, mode) and ("file", path, mode, bytes)."""
    out = b"LTPK1\0\0\0"
    for item in items:
        kind, path, mode = item[0], item[1], item[2]
        data = item[3] if kind == "file" else b""
        p = path.encode() + b"\0"
        p += b"\0" * (-len(p) % 4)
        out += struct.pack("<IIII", 1 if kind == "dir" else 2, mode, len(p), len(data)) + p
        out += data + b"\0" * (-len(data) % 4)
    return out + struct.pack("<IIII", 0, 0, 0, 0)


def run_unpack(args, archive, short_reads=False, fail_open=None):
    from unicorn.arm_const import UC_ARM_REG_CPSR
    uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
    uc.mem_map(0x1000, 0x1000)
    uc.mem_write(0x1000, unpack_blob)
    entry = struct.unpack_from("<I", unpack_blob, 28 + 56 + 124 + 16 + 15 * 4)[0]
    stack, strings = 0x80000, 0x90000
    uc.mem_map(stack - 0x10000, 0x30000)
    ptrs, at = [], strings
    for a in args:
        uc.mem_write(at, a.encode() + b"\0")
        ptrs.append(at)
        at += len(a) + 1
    uc.mem_write(stack, struct.pack(f"<I{len(ptrs)}III", len(ptrs), *ptrs, 0, 0))
    uc.reg_write(UC_ARM_REG_SP, stack)
    fs = {args[3]: bytearray(archive)} if len(args) > 3 else {}
    dirs, modes, owners, fds, log = {}, {}, {}, {}, []
    state = {"next": 3, "exit": None, "synced": False}

    def cstr(addr):
        out = b""
        while True:
            c = bytes(uc.mem_read(addr, 1))
            if c == b"\0":
                return out.decode()
            out += c
            addr += 1

    def ret(value, error=False):
        uc.reg_write(UC_ARM_REG_R0, value)
        cpsr = uc.reg_read(UC_ARM_REG_CPSR)
        uc.reg_write(UC_ARM_REG_CPSR, cpsr | (1 << 29) if error else cpsr & ~(1 << 29))

    def svc(uc, intno, _):
        n = uc.reg_read(UC_ARM_REG_R12)
        r0, r1, r2 = (uc.reg_read(r) for r in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2))
        if n == 5:                                   # open
            path = cstr(r0)
            if path == fail_open:
                return ret(13, True)
            if r1 & 1:                               # O_WRONLY | O_CREAT | O_TRUNC
                fs[path] = bytearray()
                modes[path] = r2
            elif path not in fs:
                return ret(2, True)
            fd = state["next"]
            state["next"] += 1
            fds[fd] = [path, 0]
            ret(fd)
        elif n == 3:                                 # read
            f = fds[r0]
            data = fs[f[0]][f[1]:f[1] + (min(r2, 5) if short_reads else r2)]
            f[1] += len(data)
            uc.mem_write(r1, bytes(data))
            ret(len(data))
        elif n == 4:                                 # write
            f = fds[r0]
            fs[f[0]] += bytes(uc.mem_read(r1, r2))
            ret(r2)
        elif n == 6:                                 # close
            fds.pop(r0, None)
            ret(0)
        elif n == 136:                               # mkdir
            dirs[cstr(r0)] = r1
            ret(0)
        elif n == 15:                                # chmod
            dirs[cstr(r0)] = r1
            ret(0)
        elif n == 16:                                # chown
            owners[cstr(r0)] = (r1, r2)
            ret(0)
        elif n == 124:                               # fchmod
            modes[fds[r0][0]] = r1
            ret(0)
        elif n == 123:                               # fchown
            owners[fds[r0][0]] = (r1, r2)
            ret(0)
        elif n == 10:                                # unlink
            fs.pop(cstr(r0), None)
            ret(0)
        elif n == 36:                                # sync
            state["synced"] = True
            ret(0)
        elif n == 1:                                 # exit
            state["exit"] = r0
            uc.emu_stop()
        else:
            log.append(("?", n))
            uc.emu_stop()

    uc.hook_add(UC_HOOK_INTR, svc)
    uc.emu_start(entry, 0x2000, count=5_000_000)
    return state, fs, dirs, modes, owners, log


def check_unpack(name, ok):
    print(("ok   " if ok else "FAIL ") + "lt-unpack: " + name)
    return ok


ARCH = "/tmp/lt-install.ltpk"
big = bytes((i * 7) & 0xFF for i in range(100_003))          # over three copy buffers, not a multiple of 4
items = [
    ("dir", "/var/mobile/Applications/U", 0o755),
    ("dir", "/var/mobile/Applications/U/Game.app", 0o755),
    ("file", "/var/mobile/Applications/U/Game.app/Game", 0o755, big),
    ("file", "/var/mobile/Applications/U/Game.app/Info.plist", 0o644, b"<plist/>"),
    ("file", "/var/mobile/Applications/U/Game.app/empty", 0o644, b""),
    ("dir", "/var/mobile/Applications/U/Game.app/en.lproj", 0o755),
    ("file", "/var/mobile/Applications/U/Game.app/en.lproj/a.strings", 0o644, b"abc"),
]
for short in (False, True):
    state, fs, dirs, modes, owners, log = run_unpack(["/usr/local/bin/lt-unpack", "501", "501", ARCH], pack(items),
                                                     short_reads=short)
    files_ok = all(fs.get(i[1]) == i[3] and modes.get(i[1]) == i[2] and owners.get(i[1]) == (501, 501)
                   for i in items if i[0] == "file")
    dirs_ok = all(dirs.get(i[1]) == i[2] and owners.get(i[1]) == (501, 501) for i in items if i[0] == "dir")
    good &= check_unpack("a bundle" + (" (short reads)" if short else ""),
                         state["exit"] == 0 and files_ok and dirs_ok and ARCH not in fs and state["synced"]
                         and not log)
state, fs, *_ = run_unpack(["/usr/local/bin/lt-unpack", "0", "0", ARCH], b"NOPE0000" + bytes(16))
good &= check_unpack("a bad magic is refused (2)", state["exit"] == 2)
state, fs, *_ = run_unpack(["/usr/local/bin/lt-unpack", "0", "0", ARCH], pack(items)[:200])
good &= check_unpack("a cut-off archive is refused (2)", state["exit"] == 2)
state, fs, *_ = run_unpack(["/usr/local/bin/lt-unpack", "0", "0", ARCH], pack(items),
                           fail_open="/var/mobile/Applications/U/Game.app/Info.plist")
good &= check_unpack("an unwritable file stops it (3)", state["exit"] == 3)
state, *_ = run_unpack(["/usr/local/bin/lt-unpack", "0"], b"")
good &= check_unpack("too few arguments (1)", state["exit"] == 1)
state, *_ = run_unpack(["/usr/local/bin/lt-unpack", "0", "0", "/missing"], b"")
good &= check_unpack("a missing archive (2)", state["exit"] == 2)
sys.exit(0 if good else 1)
