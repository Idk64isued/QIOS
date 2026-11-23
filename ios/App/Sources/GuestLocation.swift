import Foundation

// This phone's location, given to a device whose board has no GPS receiver.
//
// Only the iPhone 3GS's modem has a GPS receiver the emulator answers for (PhoneLocation sends it fixes). On every
// other board -- the iPhone 4, so every iOS 6 device -- Location Services found nothing however it was set. iOS 5 and
// later have another way in, the one Xcode uses on a real phone: CoreLocation's simulation interface, which locationd
// honours from a process with the com.apple.locationd.simulation entitlement. lt-locate (ios/guest-helper/lt-locate.S)
// is that process, signed with it; this puts it in the device and runs it each time this phone has moved far enough.
// Apps then see the location as they would a GPS fix.
extension GuestAgent {
    /// This phone's latest position. Sent now if the device is up, otherwise at the next watch pass.
    func simulateLocation(latitude: Double, longitude: Double) async {
        pendingLocation = (latitude, longitude)
        await flushSimulatedLocation()
    }

    /// Sends the pending position if it is news: the first one each boot, then once it has moved 25 m. Each send
    /// runs lt-locate, which waits a second and a half for locationd, so it isn't done for every small change.
    func flushSimulatedLocation() async {
        guard let target = pendingLocation, status == .alive, ops.contains("spawn"), !locationRefused else { return }
        if let sent = locationSent, Self.metres(sent, target) < 25 { return }
        guard await ensureLocator() else { return }
        let lat = String(format: "%.6f", target.latitude), lon = String(format: "%.6f", target.longitude)
        let first = locationSent == nil
        locationSent = target          // before the run: a slow one shouldn't be started again behind it
        guard let r = await run([GuestLocateBinary.guestPath, lat, lon], timeout: 20) else {
            locationSent = nil
            log("Location: lt-locate didn't answer")
            return
        }
        let out = String(decoding: r.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0 {
            if first { log("Location: the device is told it is where this phone is (simulated: \(lat), \(lon))") }
        } else {
            // Something this iOS lacks, or locationd said no (no entitlement accepted): say what, once a boot.
            locationRefused = true
            log("Location: iOS's location simulation isn't available on this device (exit \(r.status)): "
                + (out.isEmpty ? "no output" : out.replacingOccurrences(of: "\n", with: "; ")))
        }
    }

    /// Back to the device's own idea of where it is.
    func stopSimulatedLocation() async {
        pendingLocation = nil
        guard locationSent != nil, status == .alive, locateReady else { locationSent = nil; return }
        locationSent = nil
        _ = await run([GuestLocateBinary.guestPath, "stop"], timeout: 20)
        log("Location: simulation off")
    }

    /// Puts lt-locate into the guest once per boot.
    private func ensureLocator() async -> Bool {
        if locateReady { return true }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-locate")
        guard (try? GuestLocateBinary.data.write(to: tmp)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard await putFile(localURL: tmp, guestPath: GuestLocateBinary.guestPath, mode: "0755") else {
            log("Location: couldn't put lt-locate into the device")
            return false
        }
        locateReady = true
        return true
    }

    /// Distance in metres between two positions, near enough for "has it moved 25 m".
    nonisolated static func metres(_ a: (latitude: Double, longitude: Double), _ b: (latitude: Double, longitude: Double)) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let x = (b.longitude - a.longitude) * rad * cos((a.latitude + b.latitude) / 2 * rad)
        let y = (b.latitude - a.latitude) * rad
        return (x * x + y * y).squareRoot() * r
    }
}
