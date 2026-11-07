import ArgumentParser
import FirmwareSchema
import Foundation
import LightTouchCore

struct ReprepareCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reprepare",
        abstract: """
            Prepares a base again from this tree as its lock says it was prepared (entry and IPSW, identity seed, \
            recipe as prepared: boot path, options, language and keyboards), checks the new one with sessions single, \
            and only on a pass swaps it into BASE's path, unused, and removes the old copy.
            """
    )
    @Argument var base: String
    @Flag(help: "Print what would be prepared, booting and writing nothing.") var dryRun = false
    @Option(help: "The IPSW (default: the lock's, else the app's download of the same SHA-1).", transform: path)
    var ipsw: URL?
    @Option(help: "The keybag sibling's IPSW (default: the lock's, else the app's download).", transform: path)
    var siblingIpsw: URL?
    @OptionGroup var inputs: Inputs

    func run() { reprepare(self) }
}

/// `sessions reprepare BASE`: LockedPreparation's plan from BASE's lock, `firmwarekit create` into a directory beside
/// it (the same volume), `sessions single` on that, then an atomic swap (renamex_np RENAME_SWAP) once no process has
/// a file under BASE open, and the old copy removed. A run that fails anywhere leaves BASE as it was.
func reprepare(_ args: ReprepareCheck) -> Never {
    let base = Base(args.base, allowStale: true)
    let plan: LockedPreparation.Plan
    do { plan = try LockedPreparation.plan(lock: base.lock, catalog: catalogEntries) } catch { die("\(error)") }
    let fm = FileManager.default
    func found(_ given: URL?, _ recorded: String?, _ sha1: String?) -> URL? {
        if let given { return given }
        if let recorded, fm.fileExists(atPath: recorded) { return URL(fileURLWithPath: recorded) }
        return sha1.flatMap { IPSWStore.shared.existing($0) }
    }
    guard let ipsw = found(args.ipsw, plan.ipsw, plan.ipswSHA1) else {
        die("no IPSW at \(plan.ipsw) nor a download of \(plan.ipswSHA1 ?? "it"): pass --ipsw")
    }
    var siblingRow: FirmwareWire.Entry?
    var siblingIPSW: URL?
    if let from = plan.entry.recipe?.keybagRamdiskFrom {
        guard let row = catalogEntries.first(where: { $0.id == from }) else { die("the catalog has no row \(from)") }
        guard let url = found(args.siblingIpsw, plan.siblingIPSW, row.source.sha1) else {
            die("\(plan.entry.id)'s keybag ramdisk comes from \(from): pass --sibling-ipsw")
        }
        (siblingRow, siblingIPSW) = (row, url)
    }
    // The decrypt cache the base was made with, unless it lived inside the base.
    let decrypted = (base.lock["inputs"] as? [String: Any])?["decrypted"] as? String
    let cache = decrypted.flatMap { $0.components(separatedBy: "/decrypted-v2").first }
        .map { URL(fileURLWithPath: $0) }
        .flatMap { fm.fileExists(atPath: $0.path) && !$0.path.hasPrefix(base.url.path + "/") ? $0 : nil }

    print("\(plan.entry.id) from \(ipsw.path), seed \(plan.seed ?? "none")")
    print(
        "language \(plan.language ?? "the Mac's"), keyboards "
            + (plan.keyboards?.joined(separator: ",") ?? "the Mac's")
    )
    let new = base.url.deletingLastPathComponent().appendingPathComponent(".\(base.url.lastPathComponent).reprepare")
    var single = ["single", new.path]
    if plan.option("skip_setup") { single.append("--skip-setup") }
    if plan.option("jailbreak") { single.append("--jailbreak") }
    if let language = plan.language { single += ["--language", language] }

    let work = workDirectory(args.inputs, "reprepare")
    let entryFile = work.appendingPathComponent("entry.json")
    let siblingFile = work.appendingPathComponent("sibling-entry.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        try encoder.encode(plan.entry).write(to: entryFile)
        if let siblingRow { try encoder.encode(siblingRow).write(to: siblingFile) }
    } catch { die("can't write \(entryFile.path): \(error)") }
    func create(_ tools: Tools?) -> FirmwareCommand.Create {
        plan.create(
            entryFile: entryFile,
            out: new,
            ipsw: ipsw,
            cache: cache,
            guestTools: tools?.guest.appendingPathComponent("guest-tools"),
            sibling: siblingIPSW.map { (siblingFile, $0) }
        )
    }
    if args.dryRun {
        print("would run: firmwarekit \(create(nil).arguments.joined(separator: " "))")
        print("then: sessions \(single.joined(separator: " ")), and on a pass swap it into \(base.url.path)")
        exit(0)
    }

    let tools = Tools.resolve(args.inputs, work: work)
    if fm.fileExists(atPath: new.path) { try? DeviceStateStorage.removeTree(new) }  // a failed run's
    var environment = ProcessInfo.processInfo.environment.merging(driverEnvironment(tools)) { $1 }
    if let patcher = vendorDirectory()?.appendingPathComponent("MacOS/iBoot32Patcher"),
        fm.isExecutableFile(atPath: patcher.path)
    {
        environment["FIRMWAREKIT_IBOOT_PATCHER"] = patcher.path
    }
    let log = work.appendingPathComponent("create.log")
    print("preparing \(new.path) (log \(log.path))")
    fflush(stdout)
    guard run(tools.firmwarekit.path, create(tools).arguments, log: log, environment: environment) == 0 else {
        die("firmwarekit create failed; see \(log.path) (\(new.path) left for a look)")
    }
    guard sessions(single, args.inputs) == 0 else {
        die("sessions single on \(new.path) failed: \(base.url.path) left as it was")
    }
    let users = output("/usr/sbin/lsof", ["+D", base.url.path]).split(separator: "\n").dropFirst()
    guard users.isEmpty else {
        die(
            "\(base.url.path) is in use, not swapped (the new base stays at \(new.path)):\n"
                + users.joined(separator: "\n")
        )
    }
    guard renamex_np(new.path, base.url.path, UInt32(RENAME_SWAP)) == 0 else {
        die("can't swap \(new.path) into \(base.url.path): \(String(cString: strerror(errno)))")
    }
    do { try DeviceStateStorage.removeTree(new) } catch { print("the old copy stays at \(new.path): \(error)") }
    print("swapped into \(base.url.path); the old copy removed")
    _ = Base(base.url.path, allowStale: true)
    _ = prune(work)
    exit(0)
}
