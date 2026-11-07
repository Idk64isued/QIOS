import Foundation
import SessionKit

/// `sessions pair IPOD_BASE IPAD_BASE`: two devices at once, each in its own helper with its own usbmuxd (session-driver's
/// run()): a prepared base's first-boot files on a fake base; both lit at once with live heartbeats; each lock slider
/// dragged and a screenshot of each; lockdown through each usbmuxd reaches its own device; one IPA into each through the
/// one gate; kill -9 of the iPad's helper is noticed while the iPod keeps running; a fresh iPad helper on the same overlay
/// lights and answers; Stop halts both at once; the bases are untouched.
func pair(_ args: PairCheck) -> Never {
    let ipod = Base(args.ipodBase, args.inputs)
    let ipad = Base(args.ipadBase, args.inputs)
    guard ipod.board == "n72ap", ipad.board == "k48ap" else { die("pair boots an n72ap base and a k48ap base") }
    let work = workDirectory(args.inputs, "pair")
    let tools = Tools.resolve(args.inputs, work: work)
    let ipa = args.ipa ?? checkout("qemu-ios").appendingPathComponent("contrib/it-harness/build/Harness.ipa")
    let before = (SessionJudge.tree(ipod.url), SessionJudge.tree(ipad.url))
    var config = driverConfig(tools, work: work, ipa: ipa)
    config["ipodBase"] = ipod.url.path
    config["ipadBase"] = ipad.url.path
    if !args.noOffer {
        config["ipadItpack"] = tools.guest.appendingPathComponent("guest-tools/armv7.itpack").path
    }
    config["timeout"] = 900
    let (e, status) = sessionDriver(config, work: work, timeout: 900, environment: driverEnvironment(tools))
    let r = Report()

    let prep = e.one("preparedFiles")
    r.check(
        prep.bool("kboot") && prep.bool("nand") && prep.bool("overlay") && prep.bool("missingThrows"),
        "prepared: kboot.bin and nand/ from the base, overlay created, a base without them refused"
    )
    r.check(
        prep.bool("cloneMatches") && (prep.int("cloneMode") ?? 0) & 0o200 != 0 && prep.bool("secondBootKeeps")
            && prep.bool("baseUntouched"),
        "prepared: NOR cloned, mode \(String(prep.int("cloneMode") ?? 0, radix: 8)) (u+w), kept on the next boot, base unchanged"
    )
    let hellos = e.find("hello")
    r.check(
        Set(hellos.compactMap { $0.int("pid") }).count >= 3
            && hellos.allSatisfy { !($0.string("dylib") ?? "").isEmpty },
        "one helper per device (+ the restart): pids \(hellos.compactMap { $0.int("pid") })"
    )
    var geometry: [String: [Int]] = [:]
    for h in hellos { geometry[h.string("device") ?? ""] = [h.int("width") ?? 0, h.int("height") ?? 0] }
    let mismatch = e.find("log").contains { ($0.string("message") ?? "").contains("display:") }
    r.check(
        geometry["ipod"] == [320, 480] && geometry["ipad"] == [1024, 768] && !mismatch,
        "hello's device info matches the Board, no mismatch logged: \(geometry)"
    )
    let lit = e.find("lit")
    r.check(
        lit.contains { $0.string("device") == "ipod" } && lit.contains { $0.string("device") == "ipad" },
        "both lit: "
            + lit.map { "\($0.string("device") ?? "") \(format($0.double("seconds"))) s" }.joined(separator: ", ")
    )
    let both = e.one("concurrent")
    r.check(
        (both.int("ipodPID") ?? 0) > 0 && (both.int("ipadPID") ?? 0) > 0 && both.int("ipodPID") != both.int("ipadPID")
            && (both.int("ipodHeartbeat") ?? 0) > 0 && (both.int("ipadHeartbeat") ?? 0) > 0,
        "both helpers alive at once, heartbeats advancing"
    )
    var shots: [String: Event] = [:]
    for s in e.find("screenshot") {
        if let p = s.string("path") { shots[URL(fileURLWithPath: p).lastPathComponent] = s }
    }
    for d in ["ipod", "ipad"] {
        let lock = shots["\(d)-lock.png"]
        let home = shots["\(d)-home.png"]
        r.check(
            (home?.int("serial") ?? 0) > (lock?.int("serial") ?? Int.max),
            "input + screenshot \(d): a new frame after the slide"
        )
    }
    var usb: [String: String] = [:]
    for u in e.find("usb") { usb[u.string("device") ?? ""] = u.string("productType") }
    r.check(usb["ipod"] == "iPod2,1" && usb["ipad"] == "iPad1,1", "each usbmuxd reaches its own device: \(usb)")
    let installed = e.find("installed")
    r.check(
        ["ipod", "ipad"].allSatisfy { d in installed.contains { $0.string("device") == d && $0.bool("has") } },
        "IPA installed into each through the gate: "
            + installed.map { "\($0.string("device") ?? "") \(format($0.double("seconds"), 0)) s" }.joined(
                separator: ", "
            )
    )
    if !args.noOffer {
        let offer = e.one("offer", ["device": "ipad"])
        let report = e.one("ipadReport")
        r.check(
            (offer.int("serial") ?? -1) > 0 && report.int("serial") == offer.int("serial")
                && (report.int("result") ?? -99) >= 0,
            "iPad guest package: offered serial \(offer.int("serial") ?? -1), the loader reports serial \(report.int("serial") ?? -1) result \(report.int("result") ?? -99)"
        )
        let agent = e.one("ipadAgent")
        r.check(
            agent.bool("alive") && agent.string("home") == "Home Screen" && agent.int("locked") == 0
                && agent.string("launched") == "Safari",
            "iPad agent through GuestServices: foreground \(agent.string("home") ?? ""), locked \(agent.int("locked") ?? -1), launch -> \(agent.string("launched") ?? "")"
        )
    }
    let killed = e.one("killed")
    let signaled = e.find("log").contains {
        ($0.string("message") ?? "").contains("helper \(killed.int("pid") ?? -1): signaled(9)")
    }
    r.check(
        killed.bool("noticed") && (killed.double("seconds") ?? 9) < 1 && signaled
            && (killed.string("reason") ?? "").contains("stopped unexpectedly"),
        "kill -9 of the iPad's helper: noticed in \(format((killed.double("seconds") ?? -1) * 1000, 0)) ms, signaled(9) logged: \(killed.string("reason") ?? "")"
    )
    let survivor = e.one("survivor")
    r.check(
        !survivor.bool("dead") && survivor.has("dead") && (survivor.int("heartbeat") ?? 0) > 20
            && (survivor.int("frames") ?? 0) > 0
            && survivor.string("productType") == "iPod2,1",
        "the iPod kept running: +\(survivor.int("heartbeat") ?? 0) heartbeats, +\(survivor.int("frames") ?? 0) frames, USB \(survivor.string("productType") ?? "")"
    )
    r.check(
        e.find("booted", ["device": "ipad"]).count == 2 && e.find("lit", ["device": "ipad"]).count == 2
            && e.find("usb", ["device": "ipad"]).count == 2,
        "restart: a fresh iPad helper lit and answered USB on the same overlay"
    )
    let quit = e.one("quit")
    r.check(
        quit.bool("ipodExited") && quit.bool("ipadExited") && (quit.double("seconds") ?? 99) < 5
            && quit.string("ipodReason") == "The iPod stopped." && quit.string("ipadReason") == "The iPad stopped.",
        "Stop halts both at once (pause, flush, quit; no guest shutdown) in \(format(quit.double("seconds"))) s"
    )
    let after = (SessionJudge.tree(ipod.url), SessionJudge.tree(ipad.url))
    r.check(
        after.0 == before.0 && after.1 == before.1,
        "the bases are unchanged"
            + (after.0 == before.0 ? "" : ": iPod " + SessionJudge.treeDiff(before.0, after.0))
            + (after.1 == before.1 ? "" : ": iPad " + SessionJudge.treeDiff(before.1, after.1))
    )
    r.check(e.any("done") && status == 0, "driver finished (exit \(status.map(String.init) ?? "timeout"))")
    finish(r, work: work)
}
