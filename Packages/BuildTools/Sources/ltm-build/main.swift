// scripts/ltm-build SUBCOMMAND ...: the build's tools (Packages/BuildTools); `scripts/ltm-build help SUBCOMMAND`.
// LTM_ROOT is the repository (the wrapper sets it).
import ArgumentParser
import BuildSupport
import BuildTools
import Foundation

let repository = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["LTM_ROOT"] ?? FileManager.default.currentDirectoryPath
)
let dependencyManifest = repository.appendingPathComponent("build-support/dependencies.json")

func path(_ text: String) -> URL { URL(fileURLWithPath: text) }

struct LTMBuild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ltm-build",
        subcommands: [
            VendorCommand.self, MachineOptionsCommand.self, CheckMachO.self, MergeNativeCommand.self, Sources.self,
            StaticRecord.self, NativeRecord.self, Release.self, QemuCommand.self
        ]
    )
}

/// This tool's own path and its `qemu` subcommand: a process hosting libqemu-arm.dylib.
let qemuHost = [Bundle.main.executablePath ?? CommandLine.arguments[0], "qemu"]

struct VendorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "vendor", discussion: Vendor.usage)
    @Flag(help: "Print the vendor directory for the current pins.") var print = false
    @Flag(help: "Only check what a build needs.") var check = false
    @Flag(help: "Also prepare the built-in iPod (scripts/ship).") var release = false

    func run() throws {
        let vendor = Vendor(root: repository)
        if print { return Swift.print(try vendor.directory().path) }
        let missing = try vendor.problems(release: release)
        for (what, how) in missing { Swift.print("missing: \(what)\n    \(how)") }
        fflush(stdout)
        guard missing.isEmpty else { throw ToolError("vendor: install the above, then run scripts/vendor again") }
        if check { return Swift.print("vendor: everything a build needs is here") }
        Swift.print(try vendor.build(release: release, qemuHost: qemuHost).path)
    }
}

struct MachineOptionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machine-options",
        abstract: "Print HostRuntime's MachineOptions.swift for a libqemu-arm.dylib (scripts/vendor writes it).",
        discussion: "Default: the current pins' vendor directory's dylib."
    )
    @Argument(transform: path) var dylib: URL?

    func run() throws {
        let library =
            try dylib ?? Vendor(root: repository).directory().appendingPathComponent("Frameworks/libqemu-arm.dylib")
        print(
            try MachineOptions.source(
                qemu: qemuHost + [library.path],
                machines: repository.appendingPathComponent("tests/fixtures/machines.json")
            ),
            terminator: ""
        )
    }
}

struct QemuCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qemu",
        abstract: "Run a libqemu-arm.dylib's qemu_ios_main with these arguments (machine-options' QMP host).",
        shouldDisplay: false
    )
    @Argument var dylib: String
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

    func run() throws {
        guard let handle = dlopen(dylib, RTLD_NOW | RTLD_LOCAL), let main = dlsym(handle, "qemu_ios_main") else {
            throw ToolError("qemu: \(String(cString: dlerror()))")
        }
        typealias Main = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        var argv = (["qemu"] + arguments).map { strdup($0) } + [nil]
        throw ExitCode(unsafeBitCast(main, to: Main.self)(Int32(argv.count - 1), &argv))
    }
}

struct CheckMachO: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-macho",
        abstract: "Every slice's macOS load closure."
    )
    @Option var minos = "14.0"
    @Option(help: "Default: every slice.") var arch: [String] = []
    @Flag var noWeakImports = false
    @Argument(transform: path) var files: [URL]

    func run() throws {
        for file in files {
            for arch in arch.isEmpty ? try MachOClosure.architectures(file) : arch {
                for binary in try MachOClosure.check(file, minimum: minos, arch: arch, noWeakImports: noWeakImports) {
                    print("\(arch): \(binary.path)")
                }
            }
        }
    }
}

struct MergeNativeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge-native",
        abstract: "Per-architecture native roots into one universal root."
    )
    @Argument(transform: path) var output: URL
    @Argument(transform: path) var roots: [URL]

    func run() throws { try MergeNative.merge(output: output, roots: roots) }
}

struct Sources: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "The pinned dependency sources.",
        subcommands: [Fetch.self, StageGit.self, Note.self]
    )

    struct Fetch: ParsableCommand {
        @Option var group: String
        @Option(transform: path) var destination: URL
        @Option(transform: path) var cache: [URL] = []
        @Flag var offline = false
        @Option(transform: path) var manifest: URL?

        func run() throws {
            try DependencySources.fetch(
                manifest: manifest ?? dependencyManifest,
                group: group,
                destination: destination,
                caches: cache,
                offline: offline
            )
        }
    }

    struct StageGit: ParsableCommand {
        @Option(transform: path) var source: URL
        @Option(transform: path) var destination: URL
        @Option(transform: path) var record: URL

        func run() throws { try DependencySources.stageGit(source: source, destination: destination, record: record) }
    }

    struct Note: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "A shipped package's SOURCE.txt.")
        @Argument var name: String
        @Argument var patches: [String] = []
        @Option(transform: path) var manifest: URL?

        func run() throws {
            print(try DependencySources.note(manifest: manifest ?? dependencyManifest, name: name, patches: patches))
        }
    }
}

struct StaticRecord: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "build-static-deps.sh's static-build.json.")
    @Argument(transform: path) var root: URL
    @Argument var arch: String

    func run() throws { try Records.writeStatic(source: repository, root: root, arch: arch) }
}

struct NativeRecord: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "build-package-native.sh's native-build.json.")
    @Argument(transform: path) var root: URL
    @Argument(transform: path) var staticPrefix: URL
    @Argument(transform: path) var qemu: URL
    @Argument(transform: path) var usbmuxd: URL
    @Argument var arch: String

    func run() throws {
        try Records.writeNative(
            source: repository,
            root: root,
            staticPrefix: staticPrefix,
            qemu: qemu,
            usbmuxd: usbmuxd,
            arch: arch
        )
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "scripts/ship's JSON and appcast checks.",
        subcommands: [Catalog.self, AmoreID.self, Appcast.self]
    )

    struct Catalog: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Per ID: \"<id> <sha1> <bytes> <url> <mirror url>...\" from the firmware catalog's source."
        )
        @Argument(transform: path) var catalog: URL
        @Argument var ids: [String]

        func run() throws {
            for line in try ReleaseHelper.catalog(catalog, ids: ids) { print(line) }
        }
    }

    struct AmoreID: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "amore-id",
            abstract:
                "The Amore release of BUILD: \"<id> <downloadURL>\" from the upload's answer, else the cached ones."
        )
        @Argument var build: Int
        @Argument var bundleID: String
        @Argument(transform: path) var files: [URL]

        func run() throws { print(try ReleaseHelper.amoreID(build: build, bundleID: bundleID, files: files)) }
    }

    struct Appcast: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "The appcast's item for BUILD carries NOTES and an edSignature of DMG valid for KEY."
        )
        @Argument(transform: path) var appcast: URL
        @Argument var build: String
        @Argument var key: String
        @Argument(transform: path) var dmg: URL
        @Argument(transform: path) var notes: URL

        func run() throws {
            try ReleaseHelper.appcast(appcast, build: build, key: key, dmg: dmg, notes: notes)
            print("appcast: build \(build) carries the notes and a valid edSignature")
        }
    }
}

LTMBuild.main()
