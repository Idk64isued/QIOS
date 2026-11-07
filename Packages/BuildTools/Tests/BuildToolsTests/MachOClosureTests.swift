import Foundation
import Testing

@testable import BuildSupport

/// The closure check against real Mach-O files built here (was tests/release/test-package.py's fixture half).
struct MachOClosureTests {
    func cc(_ arguments: String...) throws {
        let result = try Shell.run(["cc"] + arguments)
        try #require(result.succeeded, "\(result.error)")
    }
    func tool(_ arguments: String...) throws { try #require(try Shell.run(arguments).succeeded) }

    func failure(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch { return "\(error)" }
    }

    /// A zippered library (macOS and Mac Catalyst build versions, as the toolchain's Swift compatibility libraries
    /// are) is a macOS binary at its macOS minimum; one for Mac Catalyst alone is not.
    @Test func zipperedLibrariesAreMacOS() throws {
        try withScratch { root in
            let lib = root.appendingPathComponent("lib.c")
            try "int value(void) { return 0; }\n".write(to: lib, atomically: true, encoding: .utf8)
            let zippered = root.appendingPathComponent("zippered.dylib")
            let catalyst = root.appendingPathComponent("catalyst.dylib")
            try cc(
                "-target",
                "arm64-apple-macos14.0",
                "-darwin-target-variant",
                "arm64-apple-ios17.0-macabi",
                "-dynamiclib",
                lib.path,
                "-o",
                zippered.path
            )
            try cc("-target", "arm64-apple-ios17.0-macabi", "-dynamiclib", lib.path, "-o", catalyst.path)
            #expect(failure { try MachOClosure.check(zippered, minimum: "14.0", arch: "arm64") } == nil)
            #expect(
                failure { try MachOClosure.check(catalyst, minimum: "14.0", arch: "arm64") }?
                    .contains("not a macOS binary") == true
            )
        }
    }

    @Test func closureMinimumsBundleRelocationAndMissingDependencies() throws {
        try withScratch { root in
            let lib = root.appendingPathComponent("lib.c")
            let main = root.appendingPathComponent("main.c")
            try "int value(void) { return 0; }\n".write(to: lib, atomically: true, encoding: .utf8)
            try "extern int value(void); int main(void) { return value(); }\n".write(
                to: main,
                atomically: true,
                encoding: .utf8
            )
            for minimum in ["14.0", "26.0"] {
                let dylib = root.appendingPathComponent("lib\(minimum).dylib").path
                let exe = root.appendingPathComponent("exe\(minimum)").path
                try cc(
                    "-arch",
                    "arm64",
                    "-mmacosx-version-min=\(minimum)",
                    "-dynamiclib",
                    lib.path,
                    "-install_name",
                    dylib,
                    "-o",
                    dylib
                )
                try cc("-arch", "arm64", "-mmacosx-version-min=14.0", main.path, dylib, "-o", exe)
                let found = failure {
                    try MachOClosure.check(URL(fileURLWithPath: exe), minimum: "14.0", arch: "arm64")
                }
                if minimum == "26.0" {
                    #expect(found?.contains("requires macOS 26.0") == true, "\(found ?? "passed")")
                } else {
                    #expect(found == nil, "\(found ?? "")")
                }
            }
            let app = root.appendingPathComponent("Test.app")
            let frameworks = app.appendingPathComponent("Contents/Frameworks")
            let macos = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let executable = macos.appendingPathComponent("Test")
            try FileManager.default.copyItem(at: root.appendingPathComponent("exe14.0"), to: executable)
            func verify(_ path: URL) -> String? {
                failure { try MachOClosure.check(path, minimum: "14.0", arch: "arm64", bundle: app) }
            }
            #expect(verify(executable)?.contains("escapes relocatable bundle") == true)
            let lib14 = root.appendingPathComponent("lib14.0.dylib")
            try FileManager.default.copyItem(at: lib14, to: frameworks.appendingPathComponent("lib14.0.dylib"))
            try tool("install_name_tool", "-change", lib14.path, "@rpath/lib14.0.dylib", executable.path)
            #expect(verify(executable)?.contains("unresolved dependency") == true)
            try tool("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", executable.path)
            #expect(verify(executable) == nil)
            let tools = app.appendingPathComponent("Contents/Resources/tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let nested = tools.appendingPathComponent("tool")
            try FileManager.default.copyItem(at: executable, to: nested)
            #expect(verify(nested)?.contains("unresolved dependency") == true)
            try tool(
                "install_name_tool",
                "-delete_rpath",
                "@executable_path/../Frameworks",
                "-add_rpath",
                "@executable_path/../../Frameworks",
                nested.path
            )
            #expect(verify(nested) == nil)
            try FileManager.default.removeItem(at: frameworks.appendingPathComponent("lib14.0.dylib"))
            #expect(verify(executable)?.contains("unresolved dependency") == true)
            try FileManager.default.removeItem(at: lib14)
            #expect(
                failure {
                    try MachOClosure.check(root.appendingPathComponent("exe14.0"), minimum: "14.0", arch: "arm64")
                }?
                .contains("unresolved dependency") == true
            )
        }
    }

    @Test func weakImportsAndUniversalSlices() throws {
        try withScratch { root in
            let weak = root.appendingPathComponent("weak.c")
            try
                "extern int optional_api(void) __attribute__((weak_import));\nint value(void) { return optional_api ? optional_api() : 0; }\n"
                .write(to: weak, atomically: true, encoding: .utf8)
            let weakLib = root.appendingPathComponent("weak.dylib")
            try cc(
                "-arch",
                "arm64",
                "-mmacosx-version-min=14.0",
                "-dynamiclib",
                "-undefined",
                "dynamic_lookup",
                weak.path,
                "-o",
                weakLib.path
            )
            #expect(
                failure { try MachOClosure.check(weakLib, minimum: "14.0", arch: "arm64") } == nil,
                "a low LC_BUILD_VERSION alone cannot establish runtime compatibility"
            )
            #expect(
                failure { try MachOClosure.check(weakLib, minimum: "14.0", arch: "arm64", noWeakImports: true) }?
                    .contains("unexpected weak imports") == true
            )
            // @available's runtime check, weak in every binary that uses it (ANGLE's Metal backend), is the one allowed
            let available = root.appendingPathComponent("available.c")
            try "int newer(void) { if (__builtin_available(macOS 26, *)) return 1; return 0; }\n"
                .write(to: available, atomically: true, encoding: .utf8)
            let availableLib = root.appendingPathComponent("available.dylib")
            try cc(
                "-arch",
                "arm64",
                "-mmacosx-version-min=14.0",
                "-dynamiclib",
                available.path,
                "-o",
                availableLib.path
            )
            #expect(
                try Shell.run(["nm", "-m", availableLib.path]).output.contains(
                    "weak external __availability_version_check"
                )
            )
            #expect(
                failure { try MachOClosure.check(availableLib, minimum: "14.0", arch: "arm64", noWeakImports: true) }
                    == nil
            )

            let lib = root.appendingPathComponent("lib.c")
            let main = root.appendingPathComponent("main.c")
            try "int value(void) { return 0; }\n".write(to: lib, atomically: true, encoding: .utf8)
            try "extern int value(void); int main(void) { return value(); }\n".write(
                to: main,
                atomically: true,
                encoding: .utf8
            )
            let both = root.appendingPathComponent("both.dylib")
            let fat = root.appendingPathComponent("fat")
            try cc(
                "-arch",
                "arm64",
                "-arch",
                "x86_64",
                "-mmacosx-version-min=14.0",
                "-dynamiclib",
                lib.path,
                "-install_name",
                both.path,
                "-o",
                both.path
            )
            try cc(
                "-arch",
                "arm64",
                "-arch",
                "x86_64",
                "-mmacosx-version-min=14.0",
                main.path,
                both.path,
                "-o",
                fat.path
            )
            for arch in ["arm64", "x86_64"] {
                #expect(failure { try MachOClosure.check(fat, minimum: "14.0", arch: arch) } == nil)
            }
            try tool("lipo", both.path, "-thin", "arm64", "-output", both.path)
            #expect(
                failure { try MachOClosure.check(fat, minimum: "14.0", arch: "x86_64") }?.contains(
                    "missing x86_64 slice"
                ) == true
            )
            try "int main(void) { return 0; }\n".write(to: main, atomically: true, encoding: .utf8)
            let thin = root.appendingPathComponent("thin")
            try cc("-arch", "arm64", "-mmacosx-version-min=14.0", main.path, "-o", thin.path)
            #expect(
                failure { try MachOClosure.check(thin, minimum: "14.0", arch: "x86_64") }?.contains(
                    "missing x86_64 slice"
                ) == true
            )
        }
    }
}
