// installation_proxy: the installed-app list, install of a staged .ipa (with the
// owned idle watchdog) and uninstall, on DeviceServices' run kernel.

import Foundation
import HostServiceWire

extension DeviceServices {
    // MARK: - List

    /// Installed third-party apps, via instproxy_browse with an
    /// ApplicationType=User filter. Replaces parsing `ideviceinstaller list`.
    func installedApps() async throws -> [InstalledApp] {
        try await run(Timeouts.browse, "list apps") { device in
            let client = try IMobileDevice.startInstallationProxy(device: device)
            defer { _ = instproxy_client_free(client) }

            // ApplicationType=User: skip Apple's own bundles. Built as a plist
            // rather than via instproxy's variadic option builder (not callable from Swift).
            guard let options = IMobileDevice.encode(["ApplicationType": "User"]) else {
                throw DeviceError.unavailable
            }
            defer { plist_free(options) }

            var result: plist_t?
            let br = instproxy_browse(client, options, &result)
            guard br.ok, let result else {
                throw DeviceError.instproxy(.init(code: br.code), phase: "browse")
            }
            defer { plist_free(result) }

            let apps = (IMobileDevice.decode(result) as? [[String: Any]] ?? []).compactMap {
                (dict: [String: Any]) -> InstalledApp? in
                guard let id = dict["CFBundleIdentifier"] as? String else { return nil }
                let name =
                    (dict["CFBundleDisplayName"] as? String)
                    ?? (dict["CFBundleName"] as? String) ?? id
                let version =
                    (dict["CFBundleVersion"] as? String)
                    ?? (dict["CFBundleShortVersionString"] as? String) ?? ""
                return InstalledApp(id: id, name: name, version: version)
            }
            return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Uninstall

    func uninstall(_ bundleID: String) async throws {
        try await run(Timeouts.uninstall, "uninstall \(bundleID)") { device in
            let client = try IMobileDevice.startInstallationProxy(device: device)
            defer { _ = instproxy_client_free(client) }
            // Synchronous form: no status callback, so the return code is the
            // whole answer (unlike install, whose errors arrive in the callback).
            let ur = instproxy_uninstall(client, bundleID, nil, nil, nil)
            guard ur.ok else {
                throw DeviceError.instproxy(.init(code: ur.code), phase: "uninstall")
            }
        }
    }

    // MARK: - Install (instproxy_install + owned idle watchdog)

    /// Install `ipa`, already staged at `staged`, as a new version of an
    /// installed `bundleID` too. 3.x and later upgrade through Install itself.
    /// iPhone OS 2.x's installd refuses (ApplicationAlreadyInstalled), has no
    /// Upgrade command, and has consumed the upload by then: it is sent again
    /// and installed `replacing` the old app, which keeps the app's data.
    /// On 2.x, data a failed replacement left in the device's archive comes
    /// back with the next install of the app that succeeds.
    func install(
        _ ipa: URL,
        staged: String,
        bundleID: String,
        progress: @escaping @Sendable (Int, String) -> Void
    ) async throws {
        var restoring: String?
        if (try? await lockdownValue("ProductVersion"))?.hasPrefix("2.") == true,
            (try? await archivedApps())?.contains(bundleID) == true
        {
            restoring = bundleID
        }
        do {
            try await install(stagedPath: staged, restoring: restoring, progress: progress)
        } catch DeviceError.instproxy(.alreadyInstalled, _) {
            let again = try await stage(ipa) { _ in }
            defer { Task { await removeStaged(again) } }
            try await install(stagedPath: again, replacing: bundleID, progress: progress)
        }
    }

    /// The bundle ids installd holds an archive for (instproxy_lookup_archives).
    func archivedApps() async throws -> [String] {
        try await run(Timeouts.browse, "list archives") { device in
            let client = try IMobileDevice.startInstallationProxy(device: device)
            defer { _ = instproxy_client_free(client) }
            let options = IMobileDevice.encode([String: String]())  // 2.x drops a request without ClientOptions
            defer { if let options { plist_free(options) } }
            var result: plist_t?
            let lr = instproxy_lookup_archives(client, options, &result)
            guard lr.ok, let result else { throw DeviceError.instproxy(.init(code: lr.code), phase: "archives") }
            defer { plist_free(result) }
            return ((IMobileDevice.decode(result) as? [String: Any]) ?? [:]).keys.sorted()
        }
    }

    /// Install a staged .ipa. The owned idle watchdog is the fix for the
    /// unbounded idevice_wait_for_command_to_complete hang: with a status
    /// callback installed, errors arrive ONLY in the callback, and if installd
    /// resets mid-install nothing arrives at all — so the idle timer, not the
    /// library, is what ends the wait.
    ///
    /// `replacing`: an installed app this one replaces, the way 2.x's installd
    /// keeps an app's data across a reinstall: a documents-only archive (which
    /// removes the app), Install, then Restore into the new app's container
    /// (which consumes the archive). If the Install fails the archive stays.
    /// `restoring`: after the Install, Restore that app's archive.
    func install(
        stagedPath: String,
        replacing: String? = nil,
        restoring: String? = nil,
        progress: @escaping @Sendable (Int, String) -> Void
    ) async throws {
        let socket = self.clientSocket
        try await DeviceGate.shared.serialized(socket: socket) {
            let cancellation = InstallCancellation()
            try await withTaskCancellationHandler {
                if let id = replacing { try await Self.perform(.archiveData(id), cancellation, progress) }
                do { try await Self.perform(.install(stagedPath), cancellation, progress) } catch let error
                    as DeviceError where replacing != nil && !error.isTransient
                {
                    throw DeviceError.failed(
                        "The new version didn’t install (\(error.localizedDescription)). "
                            + "The app’s data is kept on the device and comes back the next time this app installs."
                    )
                }
                if let id = replacing ?? restoring { try await Self.perform(.restore(id), cancellation, progress) }
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    /// One installation_proxy command with a status callback.
    nonisolated private enum Command: Sendable {
        case install(String)
        case archiveData(String)
        case restore(String)
    }

    private nonisolated static func perform(
        _ command: Command,
        _ cancellation: InstallCancellation,
        _ progress: @escaping @Sendable (Int, String) -> Void
    ) async throws {
        let connection = try await installConnection()
        // Once the guest mutation begins, retain the gate until its
        // existing callback watchdog finishes. Cancelling before that
        // point closes the connection without submitting an install.
        try await Task.detached {
            try blockingInstall(
                connection: connection,
                cancellation: cancellation,
                command: command,
                progress: progress
            )
        }.value
    }

    nonisolated private final class InstallCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        /// The mutation's ownership boundary. Cancellation after this check
        /// leaves the active install owned until its terminal callback/watchdog.
        func beginMutation() throws {
            try lock.withLock { if cancelled { throw CancellationError() } }
        }
    }

    nonisolated private final class InstallConnection: OpenedHandles, @unchecked Sendable {
        let device: OpaquePointer
        let client: OpaquePointer
        init(device: OpaquePointer, client: OpaquePointer) {
            self.device = device
            self.client = client
        }
        func free() {
            _ = instproxy_client_free(client)
            _ = idevice_free(device)
        }
    }

    /// A deadline may win immediately after connection succeeds; openBeforeDeadline
    /// frees the late handles then.
    private nonisolated static func installConnection() async throws -> InstallConnection {
        // A successful startup always stores before completing the deadline.
        guard
            let connection = try await openBeforeDeadline(
                Timeouts.serviceProbe * 2,
                "install connection",
                {
                    try openInstallConnection()
                }
            )
        else { throw DeviceError.unavailable }
        return connection
    }

    private nonisolated static func openInstallConnection() throws -> InstallConnection {
        var device: OpaquePointer?
        guard IMobileDevice.openDevice(&device).ok, let device else { throw DeviceError.notAttached }
        let client: OpaquePointer
        do {
            try Task.checkCancellation()
            client = try IMobileDevice.startInstallationProxy(device: device)
        } catch {
            _ = idevice_free(device)
            throw error
        }
        let connection = InstallConnection(device: device, client: client)
        do { try Task.checkCancellation() } catch {
            connection.free()
            throw error
        }
        return connection
    }

    nonisolated private final class InstallContext {
        let box: SyncBox
        let progress: @Sendable (Int, String) -> Void
        init(_ box: SyncBox, _ progress: @escaping @Sendable (Int, String) -> Void) {
            self.box = box
            self.progress = progress
        }
    }

    /// The C status callback runs on libimobiledevice's updater thread. It only
    /// decodes and hands off — nothing that could block or throw.
    nonisolated private static let installCallback: instproxy_status_cb_t = { _, status, userData in
        guard let userData, let status else { return }
        let ctx = Unmanaged<InstallContext>.fromOpaque(userData).takeUnretainedValue()
        ctx.box.touch()

        var errName: UnsafeMutablePointer<CChar>?
        var errDesc: UnsafeMutablePointer<CChar>?
        var errCode: UInt64 = 0
        let er = instproxy_status_get_error(status, &errName, &errDesc, &errCode)
        if !er.ok || errName != nil {
            let desc =
                errDesc.map { String(cString: $0) }
                ?? errName.map { String(cString: $0) } ?? "install failed"
            errName.map { free($0) }
            errDesc.map { free($0) }
            ctx.box.finish(.failed(InstproxyError(code: er.ok ? -5 : er.code), desc))
            return
        }

        var namePtr: UnsafeMutablePointer<CChar>?
        instproxy_status_get_name(status, &namePtr)
        let name = namePtr.map { String(cString: $0) } ?? ""
        namePtr.map { free($0) }

        if name == "Complete" {
            ctx.box.finish(.done)
            return
        }

        var percent: Int32 = -1
        instproxy_status_get_percent_complete(status, &percent)
        ctx.progress(Int(percent), name)
    }

    nonisolated private static func blockingInstall(
        connection: InstallConnection,
        cancellation: InstallCancellation,
        command: Command,
        progress: @escaping @Sendable (Int, String) -> Void
    ) throws {
        typealias Operation = (
            instproxy_client_t?, UnsafePointer<CChar>?, plist_t?, instproxy_status_cb_t?, UnsafeMutableRawPointer?
        ) -> instproxy_error_t
        let (installFn, target, clientOptions): (Operation, String, [String: String]) =
            switch command {
            case .install(let path): ({ instproxy_install($0, $1, $2, $3, $4) }, path, [:])
            case .archiveData(let id): ({ instproxy_archive($0, $1, $2, $3, $4) }, id, ["ArchiveType": "DocumentsOnly"])
            case .restore(let id): ({ instproxy_restore($0, $1, $2, $3, $4) }, id, ["ArchiveType": "DocumentsOnly"])
            }
        do { try cancellation.beginMutation() } catch {
            connection.free()
            throw error
        }
        let box = SyncBox()
        let ctx = InstallContext(box, progress)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        // An empty ClientOptions, never none: iPhone OS 2.x's installation_proxy silently drops an Install
        // request without the key (libimobiledevice omits it for NULL options), so no status ever arrives.
        let options = IMobileDevice.encode(clientOptions)
        defer { if let options { plist_free(options) } }
        let ir = target.withCString { installFn(connection.client, $0, options, installCallback, ctxPtr) }
        guard ir.ok else {
            connection.free()
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
            throw DeviceError.instproxy(.init(code: ir.code), phase: "start")
        }

        // Block THIS detached thread until a terminal status or an idle/absolute
        // timeout. On timeout the updater thread may still be live, so its
        // handles are leaked deliberately rather than freed under it.
        let terminal = box.wait(idle: Timeouts.installIdle, absolute: Timeouts.installAbsolute)
        switch terminal {
        // Free the client FIRST: that is what joins libimobiledevice's status
        // updater thread. Releasing the context before the join deallocates it
        // under a thread that may still fire one more callback, and the callback
        // does takeUnretainedValue → a write through a freed NSCondition.
        case .done:
            connection.free()
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
        case .failed(let e, let desc):
            connection.free()
            Unmanaged<InstallContext>.fromOpaque(ctxPtr).release()
            throw DeviceError.instproxy(e, phase: desc)
        case nil:
            // Deliberately leaks the client and the device handle: freeing them
            // here would free them under libimobiledevice's own updater thread,
            // which is still live. Tell the accountant, though — this is the
            // one leak that never did, so the cap meant to stop leaked sessions
            // piling up could not see the very case it exists for.
            // Counted, and GIVEN BACK on a timer. The leaked handles here are
            // not a blocked thread — blockingInstall returns — so nothing else
            // will ever call returned() for them, and three install timeouts
            // in a session would otherwise close the gate permanently: every
            // later device operation failing with "still waiting for earlier
            // requests" until the app is relaunched. The cap exists to stop a
            // pile-up, not to become one.
            AbandonedWork.abandoned("install")
            Task.detached {
                try? await Task.sleep(for: .seconds(Timeouts.installIdle))
                AbandonedWork.returned()
            }
            throw DeviceError.timedOut(operation: "install")
        }
    }

    // MARK: - Service readiness

    /// Does installation_proxy answer right now? A fresh boot brings lockdownd
    /// up ~40s before its services, so "lockdown replies" ≠ "installd is ready".
    func installProxyReady() async -> Bool {
        (try? await run(Timeouts.serviceProbe, "installd probe") { device in
            let client = try IMobileDevice.startInstallationProxy(device: device)
            _ = instproxy_client_free(client)
            return true
        }) ?? false
    }
}
