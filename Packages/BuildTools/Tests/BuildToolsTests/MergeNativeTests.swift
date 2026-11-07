import Foundation
import Testing

@testable import BuildTools

/// MergeNative on real Mach-O slices: a one-step arm64 root and a staged-layout x86_64 root (prefix a symlink into its
/// reused deps, QEMU built elsewhere) merge into one universal root with build paths relocated.
struct MergeNativeTests {
    func sh(_ arguments: String...) throws -> String { try output(arguments) }

    func sliceRoot(_ work: URL, _ arch: String, staged: Bool) throws -> URL {
        let root = work.appendingPathComponent(arch)
        let deps = staged ? work.appendingPathComponent("deps-\(arch)") : root
        let prefix = deps.appendingPathComponent("prefix")
        let staticLib = deps.appendingPathComponent("static/prefix")
        let qemu = staged ? work.appendingPathComponent("qemu-\(arch)") : root.appendingPathComponent("qemu-build")
        for dir in [
            prefix.appendingPathComponent("lib/pkgconfig"), prefix.appendingPathComponent("include"),
            prefix.appendingPathComponent("share"),
            staticLib.appendingPathComponent("lib"), qemu, root.appendingPathComponent("build/usbmuxd/src")
        ] {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if staged {
            try files.createSymbolicLink(at: root.appendingPathComponent("prefix"), withDestinationURL: prefix)
        }
        let lib = work.appendingPathComponent("lib.c")
        let main = work.appendingPathComponent("main.c")
        try "int value(void) { return 1; }\n".write(to: lib, atomically: true, encoding: .utf8)
        try "extern int value(void); int main(void) { return value(); }\n".write(
            to: main,
            atomically: true,
            encoding: .utf8
        )
        let dylib = prefix.appendingPathComponent("lib/libvalue.dylib").path
        let cc = ["cc", "-arch", arch, "-mmacosx-version-min=14.0"]
        _ = try output(cc + ["-dynamiclib", lib.path, "-install_name", dylib, "-o", dylib])
        _ = try output(cc + ["-c", lib.path, "-o", work.appendingPathComponent("\(arch).o").path])
        _ = try sh(
            "ar",
            "rcs",
            staticLib.appendingPathComponent("lib/libvalue.a").path,
            work.appendingPathComponent("\(arch).o").path
        )
        _ = try output(
            cc + [
                "-dynamiclib", lib.path, "-install_name", "@rpath/libqemu-arm.dylib", "-o",
                qemu.appendingPathComponent("libqemu-arm.dylib").path
            ]
        )
        let usbmuxd = root.appendingPathComponent("build/usbmuxd/src/usbmuxd")
        _ = try output(
            cc + [main.path, dylib, "-Wl,-rpath,\(prefix.appendingPathComponent("lib").path)", "-o", usbmuxd.path]
        )
        try "int value(void);\n".write(
            to: prefix.appendingPathComponent("include/value.h"),
            atomically: true,
            encoding: .utf8
        )
        try "built in \(prefix.path)\n".write(
            to: prefix.appendingPathComponent("share/where.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "arch=\(arch)\n".write(
            to: prefix.appendingPathComponent("lib/pkgconfig/value.pc"),
            atomically: true,
            encoding: .utf8
        )  // per slice: not merged
        try files.createSymbolicLink(
            atPath: prefix.appendingPathComponent("lib/libvalue.1.dylib").path,
            withDestinationPath: "libvalue.dylib"
        )
        let gdb = prefix.appendingPathComponent("share/gdb/auto-load").appendingPathComponent(
            MergeNative.real(prefix.path)
        ).appendingPathComponent("lib/libvalue-gdb.py")
        // as glib installs it
        try files.createDirectory(at: gdb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# gdb helper\n".write(to: gdb, atomically: true, encoding: .utf8)
        var record: [String: Any] = [
            "schema_version": 1, "architecture": arch, "deps_prefix": root.appendingPathComponent("prefix").path,
            "static_deps": staticLib.path, "qemu_build": qemu.path, "usbmuxd_binary": usbmuxd.path
        ]
        if staged { record["reused_native_deps"] = deps.path }
        try writeJSON(record, to: root.appendingPathComponent("native-build.json"))
        return root
    }

    func failure(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch { return "\(error)" }
    }

    @Test func mergesRelocatesAndRefuses() throws {
        let work = url(MergeNative.real(files.temporaryDirectory.path)).appendingPathComponent(
            "merge-native-test-\(UUID().uuidString)"
        )
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { remove(work) }
        let arm = try sliceRoot(work, "arm64", staged: false)
        let intel = try sliceRoot(work, "x86_64", staged: true)
        let out = work.appendingPathComponent("universal")
        try MergeNative.merge(output: out, roots: [arm, intel])
        for name in [
            "prefix/lib/libvalue.dylib", "static/prefix/lib/libvalue.a", "qemu-build/libqemu-arm.dylib",
            "build/usbmuxd/src/usbmuxd"
        ] {
            #expect(
                Set(try sh("lipo", "-archs", out.appendingPathComponent(name).path).split(separator: " ")) == [
                    "arm64", "x86_64"
                ],
                "\(name)"
            )
        }
        #expect(
            try files.destinationOfSymbolicLink(atPath: out.appendingPathComponent("prefix/lib/libvalue.1.dylib").path)
                == "libvalue.dylib"
        )
        let gdb = out.appendingPathComponent("prefix/share/gdb/auto-load").appendingPathComponent(
            out.appendingPathComponent("prefix").path
        )
        .appendingPathComponent("lib/libvalue-gdb.py")
        #expect(files.fileExists(atPath: gdb.path))
        #expect(
            !files.fileExists(atPath: out.appendingPathComponent("prefix/lib/pkgconfig").path),
            "per-slice pkg-config metadata was merged"
        )
        #expect(
            try String(contentsOf: out.appendingPathComponent("prefix/share/where.txt"), encoding: .utf8)
                == "built in \(out.path)/prefix\n"
        )
        for arch in ["arm64", "x86_64"] {
            let loads = try sh(
                "otool",
                "-arch",
                arch,
                "-l",
                out.appendingPathComponent("build/usbmuxd/src/usbmuxd").path
            )
            #expect(loads.contains("name \(out.path)/prefix/lib/libvalue.dylib "))
            #expect(loads.contains("path \(out.path)/prefix/lib "))
            #expect(!loads.contains(work.appendingPathComponent(arch).path) && !loads.contains("deps-"))
            #expect(
                try sh("otool", "-arch", arch, "-D", out.appendingPathComponent("prefix/lib/libvalue.dylib").path)
                    .split(separator: "\n").last.map(String.init) == "\(out.path)/prefix/lib/libvalue.dylib"
            )
        }
        let record = try readJSON(out.appendingPathComponent("native-build.json"))
        #expect(record["architectures"] as? [String] == ["arm64", "x86_64"])
        #expect(record["static_deps"] as? String == "\(out.path)/static/prefix")
        #expect(
            failure { try MergeNative.merge(output: out, roots: [arm, intel]) }?.contains("already exists") == true
        )
        remove(out)
        try "int value(long);\n".write(
            to: work.appendingPathComponent("deps-x86_64/prefix/include/value.h"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            failure { try MergeNative.merge(output: out, roots: [arm, intel]) }?.contains(
                "differs between architectures"
            ) == true
        )
        #expect(!files.fileExists(atPath: out.path), "a failed merge left its output")
        #expect(
            failure { try MergeNative.merge(output: out, roots: [arm, arm]) }?.contains("Two native roots for arm64")
                == true
        )
    }
}
