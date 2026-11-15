#!/usr/bin/env python3
"""Proves precheck.py still catches the mistakes that have broken real builds.

Copies ios/App/Sources to a temporary folder, injects each past mistake on its own, and checks precheck flags it
(and that the untouched copy is clean apart from what the real tree already reports).

    python3 ios/scripts/precheck-selftest.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(HERE, "..", "App", "Sources")
PRECHECK = os.path.join(HERE, "precheck.py")

# (what broke, file, text to find, replacement, text the error must contain)
CASES = [
    ("calling a property as a function (update 29)",
     "LTMiOSApp.swift", "devices = Library.scan()", "devices = Library.scan(); _ = Library.devices()",
     "Library.devices is a property"),
    ("a method that doesn't exist",
     "LTMiOSApp.swift", "devices = Library.scan()", "devices = Library.scann()", "no member 'scann'"),
    ("a method hiding the system send() (update 27)",
     "USB/TCPUSB.swift", "transact(", "send(", "resolves to TCPUSBTransport.send"),
    ("Int32 from the emulator stored in an Int (update 27)",
     "DeviceControls.swift", "if level != backlight { backlight = level }", "if raw != backlight { backlight = raw }",
     "backlight is Int but raw is Int32"),
    ("wrong argument label",
     "DeviceControls.swift", "func powerOffDevice() -> Bool {", "func powerOffDevice() -> Bool {\n        rotate(clockwize: true)",
     "rotate(clockwize:) matches none"),
    ("an iOS 17 API",
     "SettingsView.swift", "var body: some View {", "var body: some View {\n        let _ = ContentUnavailableView(\"x\", systemImage: \"y\")",
     "ContentUnavailableView (iOS 17)"),
    ("a nested type used by its simple name outside its parent (update 33)",
     "PhotoImport.swift", "throw GuestAgent.InstallFailure(message: \"\\(title) has no length.\")",
     "throw InstallFailure(message: \"\\(title) has no length.\")",
     "'InstallFailure' is declared inside GuestAgent"),
    ("a syntax error",
     "Modem.swift", "import Foundation", "import Foundation\nfunc broken( {", "does not parse"),
]


def run(folder):
    p = subprocess.run([sys.executable, PRECHECK, folder], capture_output=True, text=True)
    return p.returncode, p.stdout


def main():
    base_code, base_out = run(SOURCES)
    baseline = {l.split(": error: ", 1)[1] for l in base_out.splitlines() if ": error: " in l}
    failures = 0
    for what, rel, find, repl, expect in CASES:
        with tempfile.TemporaryDirectory() as tmp:
            dst = os.path.join(tmp, "Sources")
            shutil.copytree(SOURCES, dst)
            path = os.path.join(dst, rel)
            src = open(path, encoding="utf-8").read()
            if find not in src:
                print(f"SKIP  {what}: '{find}' is no longer in {rel} (update this case)")
                failures += 1
                continue
            open(path, "w", encoding="utf-8").write(src.replace(find, repl))
            code, out = run(dst)
            new = [l for l in out.splitlines() if ": error: " in l and l.split(": error: ", 1)[1] not in baseline]
            if code != 0 and any(expect in l for l in new):
                print(f"ok    {what}")
            else:
                print(f"MISS  {what}\n{out}")
                failures += 1
    print(f"precheck self-test: {len(CASES) - failures}/{len(CASES)} caught")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
