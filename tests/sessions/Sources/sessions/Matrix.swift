import ArgumentParser
import FirmwareSchema
import Foundation
import LightTouchCore
import SessionKit

struct MatrixCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "matrix",
        abstract:
            "Many rows at once: each job's base prepared (or given) and checked, in lanes that share the Mac's emulator slots.",
        discussion: """
            JOBS is a file (- for standard input) of one job a line, # for a comment:
              NAME BASE [-- CHECK [FLAGS]]                     a prepared base
              NAME --id ROW --ipsw IPSW [CREATE FLAGS] [-- …]  firmwarekit create first (--jailbreak, --skip-setup, …)
            The check defaults to single with the flags the base was prepared for (--jailbreak, --skip-setup, \
            --language). Up to --lanes jobs run at once; a job's preparation holds an emulator slot for its boot, and \
            the check takes its own, so a row prepares while others boot. The tools are built once. One line a job, \
            then the verdict; exit 0 when every job passed. A prepared base is removed after its check unless \
            --keep-work.
            """
    )
    @Argument(help: "The jobs file, or - for standard input.") var jobs: String
    @Option(help: "Jobs at once.") var lanes = 3
    @OptionGroup var inputs: Inputs

    func run() { matrix(self) }
}

/// The flags sessions single takes for how a base was prepared (its lock's recipe options and language).
func preparedFlags(_ base: Base) -> [String] {
    guard let plan = try? LockedPreparation.plan(lock: base.lock, catalog: catalogEntries) else { return [] }
    var flags: [String] = []
    if plan.option("skip_setup") { flags.append("--skip-setup") }
    if plan.option("jailbreak") { flags.append("--jailbreak") }
    if let language = plan.language { flags += ["--language", language] }
    return flags
}

/// Waits until scripts/host-ready says READY (load, a free slot, disk), saying why once.
func waitHostReady(_ name: String) {
    var said = false
    while true {
        let line = output(repository.appendingPathComponent("scripts/host-ready").path, [])
        if line.hasPrefix("READY") { return }
        if !said {
            print("\(name): waiting: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            fflush(stdout)
            said = true
        }
        sleep(15)
    }
}

func matrix(_ args: MatrixCheck) -> Never {
    let text: String
    do {
        text =
            args.jobs == "-"
            ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            : try String(contentsOf: path(args.jobs), encoding: .utf8)
    } catch { die("can't read \(args.jobs): \(error)") }
    let jobs: [MatrixJob]
    do { jobs = try MatrixJob.parse(text) } catch { die("\(error)") }
    guard !jobs.isEmpty else { die("no jobs in \(args.jobs)") }
    guard Set(jobs.map(\.name)).count == jobs.count else { die("job names must differ") }

    var inputs = args.inputs
    inputs.keepWork = true  // the matrix's own directory; each job prunes its own
    let work = workDirectory(inputs, "matrix")
    let app = Tools.bundle(args.inputs, work: work)
    let firmwarekit = app.appendingPathComponent("Contents/MacOS/firmwarekit")
    let helper = app.appendingPathComponent("Contents/MacOS/LightTouchDevice")
    let guestTools = Tools.unpack(app.appendingPathComponent("Contents/Resources/Guest/guest.aar"), into: work)
        .appendingPathComponent("guest-tools")
    var env = ProcessInfo.processInfo.environment
    env["LTM_EMULATOR_SLOT_HELD"] = nil
    env["LTM_STATE_DIR"] = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-sessions-state").path
    env["LTM_HOST_SERVICE_WORKER"] = app.appendingPathComponent("Contents/MacOS/LightTouchServices").path
    env["FIRMWAREKIT_IBOOT_PATCHER"] = app.appendingPathComponent("Contents/MacOS/iBoot32Patcher").path
    let environment = env
    let allowStale = args.inputs.allowStale
    let keepWork = args.inputs.keepWork
    let requirement = args.inputs.requirement ?? (args.inputs.app == nil ? Tools.teamRequirement : nil)
    let lanes = DispatchSemaphore(value: max(1, args.lanes))
    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = []
        var failed = 0
    }
    let results = Results()
    let group = DispatchGroup()
    let started = Date()
    for job in jobs {
        lanes.wait()
        group.enter()
        Thread.detachNewThread {
            defer {
                lanes.signal()
                group.leave()
            }
            let dir = work.appendingPathComponent(job.name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var prepareSeconds: Double?
            var basePath = job.base
            func report(_ pass: Bool, _ what: String) {
                let line =
                    "\(pass ? "PASS" : "FAIL") \(job.name)"
                    + (prepareSeconds.map { " (prepared in \(Int($0)) s)" } ?? "") + ": \(what)"
                results.lock.lock()
                results.lines.append(line)
                if !pass { results.failed += 1 }
                print(line)
                fflush(stdout)
                results.lock.unlock()
            }
            if basePath == nil {
                let out = dir.appendingPathComponent("base")
                waitHostReady(job.name)
                // The preparation's one-shot boot is an emulator: its slot is held for the whole create.
                let slot = EmulatorSlot.wait { print("\(job.name): waiting for an emulator slot") }
                let t = Date()
                let status = run(
                    firmwarekit.path,
                    ["create"] + job.create + [
                        "--catalog",
                        repository.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json")
                            .path,
                        "--out", out.path, "--cache", dir.appendingPathComponent("cache").path,
                        "--guest-tools", guestTools.path, "--helper", helper.path
                    ],
                    log: dir.appendingPathComponent("create.log"),
                    environment: environment
                )
                close(slot.fd)
                prepareSeconds = Date().timeIntervalSince(t)
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("cache"))
                guard status == 0 else {
                    report(false, "firmwarekit create exited \(status) (\(dir.path)/create.log)")
                    return
                }
                basePath = out.path
            }
            guard let basePath else { return }
            let check: [String]
            if job.check.isEmpty {
                guard FileManager.default.fileExists(atPath: basePath + "/device.lock.json") else {
                    report(false, "\(basePath) is not a prepared base")
                    return
                }
                check = ["single", basePath] + preparedFlags(Base(basePath, allowStale: true))
            } else {
                check = [job.check[0], basePath] + job.check.dropFirst()
            }
            waitHostReady(job.name)
            var arguments = check + ["--work", dir.appendingPathComponent("run").path, "--app", app.path]
            // The tools as Tools.resolve would pin them: this tree's build to the team, an --app to itself.
            if let requirement { arguments += ["--requirement", requirement] }
            if allowStale { arguments.append("--allow-stale") }
            if keepWork { arguments.append("--keep-work") }
            let log = dir.appendingPathComponent("check.out")
            let t = Date()
            let status = run(Bundle.main.executableURL!.path, arguments, log: log, environment: environment)
            let last =
                ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").last.map(String.init)
                ?? "no output"
            report(status == 0, "\(check[0]) in \(Int(Date().timeIntervalSince(t))) s: \(last)")
            if job.base == nil, !keepWork {
                try? DeviceStateStorage.removeTree(URL(fileURLWithPath: basePath))
            }
        }
    }
    group.wait()
    let (lines, failed) = (results.lines, results.failed)
    let summary = "\(jobs.count - failed)/\(jobs.count) jobs passed in \(Int(Date().timeIntervalSince(started))) s"
    let first = lines.first { $0.hasPrefix("FAIL") }.map { String($0.dropFirst(5)) + " " } ?? ""
    try? (lines + ["", summary, ""]).joined(separator: "\n")
        .write(to: work.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(at: work.appendingPathComponent("tools"))  // an unshared build's
    print("\(failed == 0 ? "PASS" : "FAIL") \(first)(\(summary)) \(work.path)")
    exit(failed == 0 ? 0 : 1)
}
