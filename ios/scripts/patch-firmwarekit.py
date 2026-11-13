#!/usr/bin/env python3
"""Make Packages/FirmwareKit build for iOS (run from the repository root, after 0001-hostruntime-ios.patch).

FirmwareKit prepares a device from an IPSW. On the Mac it shells out to hdiutil/diskutil/tar and boots helper
processes; iOS has none of that, so the app runs it in-process with the offline backend (VolumeMount.backend = .writer:
UDIFReader + HFSPlusWriter). This script only removes what cannot compile on iOS; every code path that needed a
subprocess throws a clear error there instead.

Edits are anchored on source text, not line numbers, so an upstream sync that moves code still patches. Each edit
says whether it applied; a missing anchor fails the script (the CI log then names it) unless it is already applied.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path("Packages/FirmwareKit")
problems = []


def edit(rel, old, new, *, count=1, regex=False, marker=None):
    path = ROOT / rel
    if not path.exists():
        problems.append(f"{rel}: file not found")
        return
    text = path.read_text()
    if marker and marker in text:
        print(f"  already patched: {rel}")
        return
    if regex:
        result, n = re.subn(old, new, text, count=count, flags=re.S)
    else:
        n = text.count(old)
        result = text.replace(old, new, count) if n else text
    if n == 0:
        problems.append(f"{rel}: anchor not found: {old[:70]!r}")
        return
    path.write_text(result)
    print(f"  patched: {rel}")


def wrap_span(rel, start, end, replacement, marker):
    """Wraps the text from `start` up to (not including) `end` in #if os(macOS), with `replacement` for iOS."""
    path = ROOT / rel
    text = path.read_text()
    if marker in text:
        print(f"  already patched: {rel} ({marker})")
        return
    a = text.find(start)
    b = text.find(end, a + len(start)) if a >= 0 else -1
    if a < 0 or b < 0:
        problems.append(f"{rel}: span not found: {start[:50]!r} .. {end[:50]!r}")
        return
    body = text[a:b]
    text = text[:a] + "#if os(macOS)\n" + body.rstrip("\n") + "\n#else\n" + replacement.rstrip("\n") + "\n#endif\n\n" + text[b:]
    path.write_text(text)
    print(f"  patched: {rel} ({marker})")


print("FirmwareKit -> iOS")

# --- Package.swift: the iOS platform; no swift-subprocess (it declares iOS 99) and no Unrar (C++ UnRAR, rar sources) ---
edit("Package.swift", "platforms: [.macOS(.v13)],", "platforms: [.macOS(.v13), .iOS(.v16)],", marker=".iOS(.v16)")
edit("Package.swift", r'[ \t]*\.package\(url: "https://github\.com/swiftlang/swift-subprocess\.git"[^\n]*\n', "", regex=True,
     marker="// ios: no subprocess")
edit("Package.swift", r'[ \t]*\.product\(name: "Subprocess", package: "swift-subprocess"\),?\n', "", regex=True,
     marker="// ios: no subprocess")
edit("Package.swift", r'[ \t]*\.package\(url: "https://github\.com/mtgto/Unrar\.swift\.git"[^\n]*\n', "", regex=True,
     marker="// ios: no subprocess")
edit("Package.swift", r'[ \t]*\.product\(name: "Unrar", package: "Unrar\.swift"\),?\n', "", regex=True,
     marker="// ios: no subprocess")
edit("Package.swift", "import PackageDescription", "import PackageDescription\n// ios: no subprocess, no unrar (ios/scripts/patch-firmwarekit.py)",
     marker="// ios: no subprocess")

# --- DiskImage: hdiutil/diskutil through Subprocess ---
edit("Sources/FirmwareKit/DiskImage/DiskImage.swift", "import Subprocess\n", "#if canImport(Subprocess)\nimport Subprocess\n#endif\n",
     marker="#if canImport(Subprocess)")
wrap_span(
    "Sources/FirmwareKit/DiskImage/DiskImage.swift",
    "    static func exec(_ argv: [String]) async throws -> (Int32, String) {\n        let result = try await Subprocess.run(",
    "\n}\n",
    """    /// iOS: there are no disk tools to run. Preparation uses the offline backend (VolumeMount.backend = .writer).
    static func exec(_ argv: [String]) async throws -> (Int32, String) {
        throw FirmwareError(
            .unsupported,
            "\\((argv.first.map { ($0 as NSString).lastPathComponent }) ?? "a tool") is not available on iOS (use the offline HFS writer)"
        )
    }""",
    "iOS: there are no disk tools to run",
)

# --- Preparer: helper processes (posix_spawn) and the process tree (libproc) ---
wrap_span(
    "Sources/FirmwareKit/Recipe/Preparer.swift",
    "    static func spawn(\n        _ executable: URL,",
    "    /// The sibling entry's restore ramdisk",
    """    /// iOS: there is no helper process, so the boards that boot one while preparing (a keybag or seal boot) stop here.
    static func spawn(
        _ executable: URL,
        _ arguments: [String],
        stdin: Int32?,
        stdout: Int32,
        inherit: [Int32: Int32]
    ) throws -> pid_t {
        throw FirmwareError(
            .unsupported,
            "this firmware needs a preparation boot in a helper process, which iOS cannot start; prepare it on a Mac"
        )
    }""",
    "iOS: there is no helper process",
)
wrap_span(
    "Sources/FirmwareKit/Recipe/Preparer.swift",
    "    public struct ChildProcess: Sendable {\n        let pid: pid_t",
    "    // MARK: - Files",
    """    /// iOS: preparation runs in this process; there are no children and no attached disk images to clean up.
    public struct ChildProcess: Sendable {
        let pid: pid_t
    }
    public static func childrenForCancellation() -> [ChildProcess] { [] }
    public static func stopChildren(_ children: [ChildProcess]) async {}
    public static func cancel(staging: URL) async throws {}""",
    "iOS: preparation runs in this process",
)
edit("Sources/FirmwareKit/N72/N72Recipe.swift", "FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(",
     "URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(", marker="URL(fileURLWithPath: NSHomeDirectory())")

# --- RAR sources (developer betas): Unrar.swift is left out of the iOS build ---
rar = ROOT / "Sources/FirmwareKit/Archive/RARSource.swift"
if rar.exists():
    text = rar.read_text()
    if "#if canImport(Unrar)" in text:
        print("  already patched: RARSource.swift")
    elif "import Unrar\n" not in text:
        problems.append("RARSource.swift: no `import Unrar`")
    else:
        head, rest = text.split("import Crypto\n", 1)
        rar.write_text(
            head + "#if canImport(Unrar)\nimport Crypto\n" + rest.rstrip("\n") + """
#else
import FirmwareSchema
import Foundation

/// iOS: RAR-wrapped IPSWs (developer betas) are not unpacked on the phone.
public enum RARSource {
    public static func unwrap(
        _ archive: URL,
        source: FirmwareWire.Entry.Source,
        to ipsw: URL,
        progress: ((Double) -> Void)? = nil
    ) throws {
        throw FirmwareError(.unsupported, "RAR-wrapped firmware (developer betas) cannot be unpacked on iOS")
    }
}
#endif
""")
        print("  patched: RARSource.swift")
else:
    print("  no RARSource.swift in this tree (nothing to do)")

# --- Keyboards: the Mac's input sources come from Carbon ---
edit("Sources/FirmwareKit/SystemEdits/Keyboards.swift", "import Carbon\n", "#if canImport(Carbon)\nimport Carbon\n#endif\n",
     marker="#if canImport(Carbon)")
edit(
    "Sources/FirmwareKit/SystemEdits/Keyboards.swift",
    "    static func macKeyboards(_ ids: [String]? = nil) -> [MacKeyboard] {\n",
    "    static func macKeyboards(_ ids: [String]? = nil) -> [MacKeyboard] {\n"
    "        #if !canImport(Carbon)\n"
    "            // iOS has no Text Input Sources API: the device gets its language's own default keyboards.\n"
    "            return []\n"
    "        #else\n",
    marker="iOS has no Text Input Sources API",
)
edit(
    "Sources/FirmwareKit/SystemEdits/Keyboards.swift",
    "        return (ids ?? order).compactMap { found[$0] }\n    }\n",
    "        return (ids ?? order).compactMap { found[$0] }\n        #endif\n    }\n",
    marker="found[$0] }\n        #endif",
)

# --- Stand-ins for the macOS-only types the remaining code names (they never run on iOS) ---
SHIM = '''// Added by ios/scripts/patch-firmwarekit.py. iOS only.
//
// FirmwareKit names a few macOS-only types in code paths iOS never takes: Foundation's Process (tar, ssh-keygen,
// iBoot32Patcher) and HostRuntime's helper-process types (the keybag and seal boots). These stand-ins let that code
// compile unchanged; anything that would have started a process throws instead.
#if !os(macOS)
import Foundation

final class Process {
    var executableURL: URL?
    var arguments: [String]?
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    var terminationStatus: Int32 { 127 }
    func run() throws {
        throw CocoaError(
            .featureUnsupported,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\\(executableURL?.lastPathComponent ?? "a tool") cannot be run on iOS (no subprocesses)"
            ]
        )
    }
    func waitUntilExit() {}
}
#endif
'''
SHIM_HOST = '''
#if !os(macOS)
import HostRuntime

enum SandboxExtension {
    enum Access: Hashable, Sendable { case read, readWrite }
    struct Grant: Hashable, Sendable {
        var path: String
        var access: Access
        init(_ url: URL, _ access: Access) {
            path = url.standardizedFileURL.path
            self.access = access
        }
    }
    enum Holder { case pid(pid_t) }
    static func issue(_ grants: [Grant], to holder: Holder, deny: [URL] = []) -> (tokens: [String], refused: [String]) {
        ([], [])
    }
}

struct HelperLaunch {
    enum Mode { case oneshot(config: String) }
    init(_ mode: Mode) {}
    var arguments: [String] { [] }
}

extension HelperSandbox {
    static func isSandboxed(_ helper: URL) -> Bool { false }
    static func emulatorGrants(helper: URL) -> [SandboxExtension.Grant] { [] }
}
#endif
'''
for rel, content in [
    ("Sources/FirmwareKit/iOSShims.swift", SHIM + SHIM_HOST),
    ("Sources/FirmwareSchema/iOSShims.swift", SHIM),
]:
    (ROOT / rel).write_text(content)
    print(f"  wrote: {rel}")

if problems:
    print("\nFirmwareKit iOS patch: these edits did not apply (upstream changed?):", file=sys.stderr)
    for p in problems:
        print("  - " + p, file=sys.stderr)
    sys.exit(1)
print("FirmwareKit iOS patch applied.")
