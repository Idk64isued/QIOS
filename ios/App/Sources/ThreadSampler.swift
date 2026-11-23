import Darwin
import Foundation

/// A small sampling profiler for the emulator's own threads, written to the log every 15 seconds.
///
/// The question it answers: when the emulator gets slow, where is the virtual CPU's thread? The emulator's own
/// accounting (IT_VCPU_ACCT) shows it spending more and more of its time outside the guest and asleep, but not why.
/// Ten times a second this stops that thread for a few microseconds, reads its stack (frame pointers), and lets
/// it go; every 15 seconds it logs what share of the samples ran guest code, waited in the kernel, or ran the
/// emulator, and the commonest stacks. Addresses in the emulator library print as `libqemu-arm.dylib+0x…`; CI keeps
/// that library's symbol map (build-logs → qemu-symbols.txt) to turn them into function names.
///
/// Nothing here allocates while the thread is stopped (it could be holding the allocator's lock): the stack goes
/// into a buffer made beforehand, read with vm_read_overwrite, which fails cleanly on a bad pointer instead of
/// crashing.
enum ThreadSampler {
    private static let depth = 12
    // Ten samples a second: every sample stops the virtual CPU for a moment, so fifty a second (as it was) cost the
    // device speed and the phone heat; a 15-second window still gets 150 samples per thread.
    private static let interval: useconds_t = 100_000         // 10 samples a second
    private static let window: TimeInterval = 15

    static func start(while keepGoing: @escaping () -> Bool) {
        let thread = Thread { run(keepGoing) }
        thread.name = "ltm-sampler"
        thread.qualityOfService = .utility
        thread.start()
    }

    // MARK: - Finding the threads

    private struct Target {
        let port: thread_act_t
        let name: String
    }

    /// The emulator's virtual CPU threads ("CPU 0/TCG", named because the app passes -name debug-threads=on) and
    /// its main loop ("qemu-main").
    private static func targets() -> [Target] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        var found: [Target] = []
        let me = mach_thread_self()
        for i in 0..<Int(count) {
            let port = list[i]
            if port == me { continue }
            guard let pthread = pthread_from_mach_thread_np(port) else { continue }
            var buffer = [CChar](repeating: 0, count: 64)
            pthread_getname_np(pthread, &buffer, buffer.count)
            let name = String(cString: buffer)
            if name.hasPrefix("CPU ") || name == "qemu-main" {
                found.append(Target(port: port, name: name))
            }
        }
        mach_port_deallocate(mach_task_self_, me)
        return found
    }

    // MARK: - Sampling

    /// One stack: the pc, then return addresses, into `frames`. Returns how many it got.
    private static func sample(_ port: thread_act_t, into frames: UnsafeMutablePointer<UInt64>,
                               state: UnsafeMutablePointer<natural_t>, pair: UnsafeMutablePointer<UInt64>) -> Int
    {
        guard thread_suspend(port) == KERN_SUCCESS else { return 0 }
        // ARM_THREAD_STATE64 (6), 68 words: x0-x28, fp at byte 232, lr 240, sp 248, pc 256.
        var count = mach_msg_type_number_t(68)
        var n = 0
        if thread_get_state(port, 6, state, &count) == KERN_SUCCESS {
            let raw = UnsafeMutableRawPointer(state)
            let mask: UInt64 = 0x0000_007F_FFFF_FFFF             // drop pointer-authentication bits
            var fp = raw.load(fromByteOffset: 232, as: UInt64.self) & mask
            frames[0] = raw.load(fromByteOffset: 256, as: UInt64.self) & mask
            frames[1] = raw.load(fromByteOffset: 240, as: UInt64.self) & mask
            n = 2
            while n < depth, fp != 0, fp & 7 == 0 {
                var got: vm_size_t = 0
                let kr = vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16,
                                           vm_address_t(UInt(bitPattern: pair)), &got)
                guard kr == KERN_SUCCESS, got == 16 else { break }
                let next = pair[0] & mask, ret = pair[1] & mask
                if ret == 0 { break }
                if n > 2 || ret != frames[1] {             // the first saved lr is usually the lr already taken
                    frames[n] = ret
                    n += 1
                }
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(port)
        return n
    }

    private static func run(_ keepGoing: @escaping () -> Bool) {
        // Wait for the emulator to have started its threads.
        var found: [Target] = []
        for _ in 0..<60 where found.isEmpty {
            sleep(1)
            found = targets().filter { $0.name.hasPrefix("CPU ") }
        }
        guard !found.isEmpty else {
            LTMLog.note("[prof] no emulator CPU thread found; profiling off")
            return
        }
        let all = targets()
        LTMLog.note("[prof] sampling \(all.map(\.name).joined(separator: ", ")) at 10 Hz, then 2 Hz after two minutes")
        let began = Date()

        let frames = UnsafeMutablePointer<UInt64>.allocate(capacity: depth)
        let state = UnsafeMutablePointer<natural_t>.allocate(capacity: 68)
        let pair = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
        defer { frames.deallocate(); state.deallocate(); pair.deallocate() }

        var stacks: [String: [String: Int]] = [:]       // thread -> stack -> samples
        var kinds: [String: [String: Int]] = [:]        // thread -> guest code / kernel wait / emulator / other
        var totals: [String: Int] = [:]
        var symbols: [UInt64: (image: String, symbol: String)] = [:]
        var windowStart = Date()

        func describe(_ address: UInt64) -> (image: String, symbol: String) {
            if let known = symbols[address] { return known }
            var info = Dl_info()
            var result = (image: "jit", symbol: String(format: "0x%llx", address))
            if address > 4096, let pointer = UnsafeRawPointer(bitPattern: UInt(address)), dladdr(pointer, &info) != 0,
                let fname = info.dli_fname
            {
                let image = (String(cString: fname) as NSString).lastPathComponent
                let base = UInt64(UInt(bitPattern: info.dli_fbase))
                if let sname = info.dli_sname, let saddr = info.dli_saddr {
                    let offset = address - UInt64(UInt(bitPattern: saddr))
                    result = (image, "\(String(cString: sname))+\(offset)")
                } else {
                    result = (image, String(format: "+0x%llx", address - base))
                }
            }
            if symbols.count < 20000 { symbols[address] = result }
            return result
        }

        while keepGoing() {
            for target in all {
                let n = sample(target.port, into: frames, state: state, pair: pair)
                guard n > 0 else { continue }
                totals[target.name, default: 0] += 1
                let leaf = describe(frames[0])
                let kind: String
                if leaf.image == "jit" {
                    kind = "guest code"
                } else if leaf.image.hasPrefix("libsystem_kernel") {
                    kind = "waiting in the kernel"
                } else if leaf.image.hasPrefix("libqemu") {
                    kind = "emulator"
                } else {
                    kind = "other (\(leaf.image))"
                }
                kinds[target.name, default: [:]][kind, default: 0] += 1
                // The stack, without the system's own frames at the top of it.
                var parts: [String] = []
                for i in 0..<n {
                    let d = describe(frames[i])
                    if parts.isEmpty, d.image.hasPrefix("libsystem_") { continue }
                    parts.append(d.image == "jit" ? "[guest code]" : "\(d.image.replacingOccurrences(of: ".dylib", with: "")):\(d.symbol)")
                    if parts.count == 5 { break }
                }
                let key = parts.isEmpty ? "(only system frames)" : parts.joined(separator: " < ")
                stacks[target.name, default: [:]][key, default: 0] += 1
            }
            // Every sample stops the guest's CPUs for a moment. Boot and an app's first minutes are where the
            // questions are; after two minutes a sample every half second still fills a window, at a fifth of the cost.
            usleep(Date().timeIntervalSince(began) > 120 ? 500_000 : interval)

            if Date().timeIntervalSince(windowStart) >= window {
                windowStart = Date()
                for target in all {
                    let total = max(totals[target.name] ?? 0, 1)
                    let share = (kinds[target.name] ?? [:]).sorted { $0.value > $1.value }
                        .map { "\($0.key) \($0.value * 100 / total)%" }.joined(separator: ", ")
                    LTMLog.note("[prof] \(target.name): \(share)")
                    for (stack, count) in (stacks[target.name] ?? [:]).sorted(by: { $0.value > $1.value }).prefix(4) {
                        LTMLog.note("[prof]   \(count * 100 / total)%  \(stack)")
                    }
                }
                stacks.removeAll()
                kinds.removeAll()
                totals.removeAll()
            }
        }
    }
}
