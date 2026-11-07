import CIMobileDevice
import Foundation
import HostServiceWire
import Testing

@testable import Engine

extension SharedState {
    /// IMobileDevice.startInstallationProxy over the fake libimobiledevice: each step's exact error (a locked device's,
    /// a prohibited service's or a transport's lockdown code is kept rather than turned into instproxy -256), the native
    /// call order (lockdown closed before the service's socket opens), cleanup of partial and null handles, and the
    /// client left to the caller on success. H handshake, S start service, L lockdown freed, D descriptor freed,
    /// N instproxy client, C client freed.
    @Suite struct EngineServiceConnectionTests {
        final class Script: @unchecked Sendable {
            var stage: Int32 = 0, error: Int32 = 0, missing: Int32 = 0, calls = ""
        }

        @Test func installationProxyConnection() throws {
            let saved = (
                IMDFake.lockdownHandshake, IMDFake.lockdownStartService, IMDFake.lockdownFree,
                IMDFake.lockdownDescriptorFree,
                IMDFake.instproxyClientNew, IMDFake.instproxyClientFree
            )
            defer {
                (
                    IMDFake.lockdownHandshake, IMDFake.lockdownStartService, IMDFake.lockdownFree,
                    IMDFake.lockdownDescriptorFree,
                    IMDFake.instproxyClientNew, IMDFake.instproxyClientFree
                ) = saved
            }
            let s = Script()
            let device = OpaquePointer(bitPattern: 17)!
            let lockdown = OpaquePointer(bitPattern: 0x10)!
            let client = OpaquePointer(bitPattern: 0x30)!
            let descriptor = UnsafeMutablePointer<lockdownd_service_descriptor>(bitPattern: 0x20)!
            IMDFake.lockdownHandshake = { d, out, label in
                #expect(d == device && String(cString: label!) == "LightTouchMac")
                s.calls += "H"
                out?.pointee = s.missing & 1 != 0 ? nil : lockdown
                return lockdownd_error_t(rawValue: s.stage == 1 ? s.error : 0)
            }
            IMDFake.lockdownStartService = { c, name, out in
                #expect(c == lockdown && String(cString: name!) == "com.apple.mobile.installation_proxy")
                s.calls += "S"
                out?.pointee = s.missing & 2 != 0 ? nil : descriptor
                return lockdownd_error_t(rawValue: s.stage == 2 ? s.error : 0)
            }
            IMDFake.lockdownFree = { c in
                #expect(c == lockdown)
                s.calls += "L"
                return LOCKDOWN_E_SUCCESS
            }
            IMDFake.lockdownDescriptorFree = { d in
                #expect(d == descriptor)
                s.calls += "D"
                return LOCKDOWN_E_SUCCESS
            }
            IMDFake.instproxyClientNew = { d, service, out in
                #expect(d == device && service == descriptor)
                #expect(s.calls == "HSL", "lockdown must close before the service's socket opens: \(s.calls)")
                s.calls += "N"
                out?.pointee = s.missing & 4 != 0 ? nil : client
                return instproxy_error_t(rawValue: s.stage == 3 ? s.error : 0)
            }
            IMDFake.instproxyClientFree = { c in
                #expect(c == client)
                s.calls += "C"
                return INSTPROXY_E_SUCCESS
            }
            func failure(
                _ stage: Int32,
                _ code: Int32,
                _ missing: Int32,
                expected: DeviceError,
                trace: String,
                sourceLocation: SourceLocation = #_sourceLocation
            ) {
                (s.stage, s.error, s.missing, s.calls) = (stage, code, missing, "")
                do {
                    _ = try IMobileDevice.startInstallationProxy(device: device)
                    Issue.record("unexpected successful connection", sourceLocation: sourceLocation)
                } catch {
                    #expect(
                        "\(error)" == "\(expected)",
                        "wrong error: \(error), expected \(expected)",
                        sourceLocation: sourceLocation
                    )
                }
                #expect(s.calls == trace, "wrong cleanup: \(s.calls)", sourceLocation: sourceLocation)
            }
            // Device locked, prohibited service and transport failures keep their exact lockdown code.
            for code: Int32 in [-17, -21, -7, -256] {
                failure(1, code, 1, expected: .lockdown(code), trace: "H")
                failure(1, code, 0, expected: .lockdown(code), trace: "HL")
                failure(2, code, 2, expected: .lockdown(code), trace: "HSL")
                failure(2, code, 0, expected: .lockdown(code), trace: "HSLD")
            }
            for code: Int32 in [-3, -4, -5, -256] {
                failure(3, code, 4, expected: .instproxy(.init(code: code), phase: "connect"), trace: "HSLND")
                failure(3, code, 0, expected: .instproxy(.init(code: code), phase: "connect"), trace: "HSLNCD")
            }
            // Broken native success-with-null outputs.
            failure(0, 0, 1, expected: .lockdown(-256), trace: "H")
            failure(0, 0, 2, expected: .lockdown(-256), trace: "HSL")
            failure(0, 0, 4, expected: .instproxy(.init(code: -256), phase: "connect"), trace: "HSLND")
            (s.stage, s.error, s.missing, s.calls) = (0, 0, 0, "")
            let opened = try IMobileDevice.startInstallationProxy(device: device)
            #expect(s.calls == "HSLND", "the helper freed the caller's client")
            _ = instproxy_client_free(opened)
            #expect(s.calls == "HSLNDC")
        }
    }
}
