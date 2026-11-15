#!/usr/bin/env python3
"""Runs lt-mkdirs under an ARM emulator (unicorn) with a kernel-style stack and checks the system calls it makes.

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
src = open(os.path.join(HERE, "..", "App", "Sources", "GuestHelperBinary.swift")).read()
blob = base64.b64decode("".join(re.findall(r'"([A-Za-z0-9+/=]+)"', src.split("data = Data(")[1])))


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
sys.exit(0 if good else 1)
