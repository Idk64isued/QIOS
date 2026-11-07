// The home screen's icon order, read and written over com.apple.springboardservices.
//
// libimobiledevice implements sbservices_get_icon_state/set_icon_state but
// ships no tool that calls them, so the library drives them directly. The
// alternative -- editing com.apple.springboard.plist in the guest -- needs a
// respring to take effect, and a respring in the middle of managing apps is a
// worse experience than the reorder is worth.
//
// The state itself is an array of pages; each page is an array of icons; an
// icon is a dict with a displayIdentifier, or a folder (never on 3.1.3) with
// children. Dock icons are page 0. Everything here flattens that to a plain
// list of bundle IDs in home-screen order and puts it back the same shape it
// came in, so pages and the dock survive a reorder untouched.

import Foundation
import HostServiceWire

extension DeviceServices {
    /// Bundle IDs in home-screen order: dock first, then each page, reading
    /// the way the icons are laid out. Throws rather than returning [] so the
    /// caller can tell "SpringBoard says there is nothing" from "we couldn't
    /// ask" — an empty list would silently reorder the sidebar to nothing.
    func homeScreenOrder() async throws -> [String] {
        try await withIconState { state, _ in HomeScreenLayout.flatten(state) }
    }

    /// Move `bundleID` into the slot `other` currently occupies, or to the end
    /// when `other` is nil. Keyed on bundle IDs rather than indices because
    /// that is what a dropped table row knows, and because the layout can
    /// change under us between the drop and the write. Returns the order
    /// SpringBoard ACCEPTED, which is not always the one asked for — the
    /// caller should adopt it rather than assume its own.
    ///
    /// Every page keeps its icon count: icons after the insertion point shuffle
    /// up one slot, exactly as dragging on the device does.
    @discardableResult
    func moveOnHomeScreen(_ bundleID: String, before other: String?, deviceName: String) async throws -> [String] {
        try await withIconState { state, client in
            var ids = HomeScreenLayout.flatten(state)
            // Not "return ids". Returning the unchanged order looked like a
            // successful move to the caller, which kept its optimistic row
            // position while the device never got the write — most likely for
            // an app SpringBoard has not added to its layout yet, i.e. a fresh
            // install before a respring.
            guard let from = ids.firstIndex(of: bundleID) else {
                throw DeviceToolsError.failed(
                    "This app isn’t on the Home screen yet. "
                        + "Restart the \(deviceName), then try moving it again."
                )
            }
            ids.remove(at: from)
            let to = other.flatMap { ids.firstIndex(of: $0) } ?? ids.count
            ids.insert(bundleID, at: to)
            try HomeScreenLayout.write(HomeScreenLayout.rebuild(state, order: ids), to: client)
            return ids
        }
    }

    /// SpringBoard's UIInterfaceOrientation (1 portrait, 2 upside down,
    /// 3 landscape right, 4 landscape left). 3.2's springboardservicesrelay
    /// answers it; 3.1.3's doesn't (see EmulatorController's auto-rotation).
    func interfaceOrientation() async throws -> Int {
        try await withSpringBoard { client in
            var orientation = SBSERVICES_INTERFACE_ORIENTATION_UNKNOWN
            guard sbservices_get_interface_orientation(client, &orientation).ok else {
                throw DeviceToolsError.failed("The Home screen didn’t report its orientation. Try again.")
            }
            return Int(orientation.rawValue)
        }
    }

    // MARK: - libimobiledevice

    /// Connect, run `body` against the current icon state, disconnect. Every
    /// handle is released on the way out, including on a throw — a leaked
    /// lockdown client is a service slot the device does not get back, and
    /// this device only has a handful.
    private func withIconState<T: Sendable>(
        _ body: @Sendable @escaping ([Any], OpaquePointer) throws -> T
    ) async throws -> T {
        try await withSpringBoard { client in
            var raw: plist_t?
            // "2" is the format version SpringBoard has spoken since iOS 3 —
            // the one that reports the dock as its own list.
            guard sbservices_get_icon_state(client, &raw, "2").ok, let raw else {
                throw DeviceToolsError.failed("The Home screen didn’t report its layout. Try again.")
            }
            defer { plist_free(raw) }

            guard let state = try HomeScreenLayout.decode(raw) as? [Any] else {
                throw DeviceToolsError.failed("The Home screen reported a layout Light Touch can’t read.")
            }
            return try body(state, client)
        }
    }

    /// Connect to springboardservices, run `body`, disconnect — on the run
    /// kernel, under the same gate and deadline as every other device
    /// operation. This was a bare detached task once: the only device path that
    /// opened a lockdown session without asking the gate first, against a guest
    /// that serves about one, so a home-screen read landing next to a list poll
    /// or an install cost both of them their services ("Invalid service"); and
    /// `lockdownd_client_new_with_handshake` has no timeout of its own.
    private func withSpringBoard<T: Sendable>(
        _ body: @Sendable @escaping (OpaquePointer) throws -> T
    ) async throws -> T {
        try await run(Timeouts.browse, "home-screen layout") { device in
            var lockdown: OpaquePointer?
            guard lockdownd_client_new_with_handshake(device, &lockdown, "LightTouchMac").ok, let lockdown else {
                throw DeviceToolsError.failed("The device refused the connection. Try again.")
            }
            defer { _ = lockdownd_client_free(lockdown) }

            var service: lockdownd_service_descriptor_t?
            guard lockdownd_start_service(lockdown, "com.apple.springboardservices", &service).ok, let service else {
                throw DeviceToolsError.failed("The Home screen isn’t responding yet. Try again in a moment.")
            }
            defer { _ = lockdownd_service_descriptor_free(service) }

            var client: OpaquePointer?
            guard sbservices_client_new(device, service, &client).ok, let client else {
                throw DeviceToolsError.failed("Couldn’t reach the Home screen. Try again.")
            }
            defer { _ = sbservices_client_free(client) }
            return try body(client)
        }
    }
}

nonisolated extension HomeScreenLayout {
    /// plist_t -> Foundation, via the XML both sides already speak. Converting
    /// through a string beats walking the plist_t node by node, and an icon
    /// layout is a few KB.
    static func decode(_ node: plist_t) throws -> Any {
        guard let state = IMobileDevice.decode(node) else {
            throw DeviceToolsError.failed("The Home screen reported a layout Light Touch can’t read.")
        }
        return state
    }

    static func write(_ state: [Any], to client: OpaquePointer) throws {
        guard let node = IMobileDevice.encode(state) else {
            throw DeviceToolsError.failed("Couldn’t save the Home screen layout.")
        }
        defer { plist_free(node) }
        guard sbservices_set_icon_state(client, node).ok else {
            throw DeviceToolsError.failed("The Home screen didn’t accept the new layout.")
        }
    }
}
