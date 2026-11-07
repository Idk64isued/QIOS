// libimobiledevice, which the services helper links (its bridging header, LightTouchServices/Lockdown/Lockdown.h,
// brings in the C API). The engine halves of Services/ call it directly; this file keeps what they share: opening the
// device, starting a service with each step's error kept, and plist <-> Foundation through the XML both sides speak.

import Foundation
import HostServiceWire

/// libimobiledevice's per-service error enums, as the Int32 codes DeviceError keeps. Zero is success in all of them.
nonisolated protocol IMobileDeviceResult: RawRepresentable, Equatable where RawValue: BinaryInteger {}
nonisolated extension IMobileDeviceResult {
    var ok: Bool { rawValue == 0 }
    var code: Int32 { Int32(truncatingIfNeeded: rawValue) }
}
nonisolated extension idevice_error_t: IMobileDeviceResult {}
nonisolated extension lockdownd_error_t: IMobileDeviceResult {}
nonisolated extension afc_error_t: IMobileDeviceResult {}
nonisolated extension instproxy_error_t: IMobileDeviceResult {}
nonisolated extension np_error_t: IMobileDeviceResult {}
nonisolated extension sbservices_error_t: IMobileDeviceResult {}
nonisolated extension house_arrest_error_t: IMobileDeviceResult {}
nonisolated extension service_error_t: IMobileDeviceResult {}

/// Nonisolated: the project defaults to MainActor isolation, and every one of these is called from the detached task
/// that does the blocking device work.
nonisolated enum IMobileDevice {
    /// The device this helper serves (LTM_SERVICE_UDID), or the only one usbmuxd has.
    static func openDevice(_ device: inout OpaquePointer?) -> idevice_error_t {
        HostServiceResources.udid.map { id in id.withCString { idevice_new(&device, $0) } } ?? idevice_new(&device, nil)
    }

    /// The library's convenience factories (instproxy_/afc_client_start_service)
    /// lose handshake/start-service errors: installation_proxy's comes back as
    /// its generic -256, AFC's as "unknown error" (1) — smoke.md #5's opaque
    /// code 1 could have been any of the three steps. Keep each failure in its
    /// own domain so a locked guest or unavailable service is not mistaken for
    /// an unresponsive device. The caller owns the returned client.
    static func startService<E: IMobileDeviceResult>(
        _ name: String,
        device: OpaquePointer,
        newClient: (OpaquePointer?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<OpaquePointer?>?) -> E,
        freeClient: (OpaquePointer?) -> E,
        connectError: (Int32) -> Error
    ) throws -> OpaquePointer {
        var lockdown: OpaquePointer?
        let handshake = lockdownd_client_new_with_handshake(device, &lockdown, "LightTouchMac")
        guard handshake.ok, let lockdown else {
            if let lockdown { _ = lockdownd_client_free(lockdown) }
            throw DeviceError.lockdown(handshake.ok ? -256 : handshake.code)
        }

        var descriptor: lockdownd_service_descriptor_t?
        let started = lockdownd_start_service(lockdown, name, &descriptor)
        // Match service_client_factory_start_service: close the temporary
        // lockdown session before connecting to the service's own socket.
        _ = lockdownd_client_free(lockdown)
        defer { if let descriptor { _ = lockdownd_service_descriptor_free(descriptor) } }
        guard started.ok, let descriptor else { throw DeviceError.lockdown(started.ok ? -256 : started.code) }

        var client: OpaquePointer?
        let connected = newClient(device, descriptor, &client)
        guard connected.ok, let client else {
            if let client { _ = freeClient(client) }
            throw connectError(connected.ok ? -256 : connected.code)
        }
        return client
    }

    static func startInstallationProxy(device: OpaquePointer) throws -> OpaquePointer {
        try startService(
            "com.apple.mobile.installation_proxy",
            device: device,
            newClient: { instproxy_client_new($0, $1, $2) },
            freeClient: { instproxy_client_free($0) },
            connectError: { DeviceError.instproxy(.init(code: $0), phase: "connect") }
        )
    }

    // MARK: - plist ↔ Foundation (via the XML both sides speak)

    /// The most of a device's plist that is converted: nodes, and string, data and key bytes. A binary plist's objects
    /// can be referenced from many places, and libplist gives every reference its own copy, so a small reply can stand
    /// for a tree vastly larger than itself; anything over these is refused rather than written out as XML.
    static let maxNodes = 1 << 20, maxBytes = 32 << 20

    /// Whether `root`'s tree is within maxNodes and maxBytes, counted node by node, stopping at the first excess.
    static func withinLimits(_ root: plist_t) -> Bool {
        var nodes = 0
        var bytes = 0
        var pending = [root]
        while let node = pending.popLast() {
            nodes += 1
            var length: UInt64 = 0
            switch plist_get_node_type(node) {
            case PLIST_ARRAY:
                for index in 0..<plist_array_get_size(node) {
                    if let item = plist_array_get_item(node, index) { pending.append(item) }
                }
            case PLIST_DICT:
                var iterator: plist_dict_iter?
                plist_dict_new_iter(node, &iterator)
                defer { free(iterator) }
                while true {
                    var key: UnsafeMutablePointer<CChar>?
                    var value: plist_t?
                    plist_dict_next_item(node, iterator, &key, &value)
                    if let key {
                        bytes += strlen(key)
                        plist_mem_free(key)
                    }
                    guard let value else { break }
                    pending.append(value)
                }
            case PLIST_STRING: _ = plist_get_string_ptr(node, &length)
            case PLIST_DATA: _ = plist_get_data_ptr(node, &length)
            default: break
            }
            bytes += Int(clamping: length)
            guard nodes + pending.count <= maxNodes, bytes <= maxBytes else { return false }
        }
        return true
    }

    /// plist_t → Foundation. nil on any failure, and for a tree over maxNodes or maxBytes. Every plist from the device
    /// (installation_proxy, springboardservices, lockdown values, house_arrest, DeviceLink) comes through here.
    static func decode(_ node: plist_t) -> Any? {
        guard withinLimits(node) else { return nil }
        var xml: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        _ = plist_to_xml(node, &xml, &length)
        guard let xml else { return nil }
        defer { plist_mem_free(xml) }
        return try? PropertyListSerialization.propertyList(from: Data(bytes: xml, count: Int(length)), format: nil)
    }

    /// Foundation → plist_t. The caller owns the result and must plist_free it.
    static func encode(_ value: Any) -> plist_t? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) else {
            return nil
        }
        var node: plist_t?
        _ = data.withUnsafeBytes { buffer in
            plist_from_xml(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(buffer.count), &node)
        }
        return node
    }

    // MARK: - Attachment

    /// Preserve the failure for the inspector and diagnostics. Attachment is
    /// only the USB bridge check; it says nothing about app-service readiness.
    /// The caller must select the endpoint through DeviceGate before opening.
    static func checkAttachment() throws {
        var device: OpaquePointer?
        guard openDevice(&device).ok, let device else { throw DeviceError.notAttached }
        _ = idevice_free(device)
    }
}
