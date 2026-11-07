import Foundation
import Testing

@testable import LightTouchCore

/// The developer connection profile: written only when the device opted in, naming the bundled forwarding tool,
/// private, the exact boot's endpoint, and retired only by the boot that wrote it.
struct DeveloperConnectionProfileTests {
    @Test func publishAndRetireArePerBoot() throws {
        try withTemporaryDirectory { folder in
            let state = folder.appendingPathComponent("state")
            let tools = folder.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let inetcat = tools.appendingPathComponent("inetcat")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: inetcat)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inetcat.path)
            let instance = UUID()
            let first = UUID()
            let second = UUID()
            let root = state.appendingPathComponent(instance.uuidString.lowercased())
            let profile = root.appendingPathComponent("connection.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            func publish(_ session: UUID, _ socket: String, _ udid: String) throws {
                try DeveloperConnectionProfile.publish(
                    instance: instance,
                    session: session,
                    socket: socket,
                    udid: udid,
                    state: state,
                    tools: tools
                )
            }
            func read() throws -> DeveloperConnectionProfile.Connection {
                try JSONDecoder().decode(DeveloperConnectionProfile.Connection.self, from: Data(contentsOf: profile))
            }

            try publish(first, "127.0.0.1:4010", "first-device")
            #expect(!FileManager.default.fileExists(atPath: profile.path), "published without opting in")
            try Data().write(to: root.appendingPathComponent("enabled"))
            try publish(first, "127.0.0.1:4010", "first-device")
            let old = try read()
            #expect(
                old.instance == instance && old.session == first && old.udid == "first-device"
                    && old.usbmux == "127.0.0.1:4010"
            )
            #expect(old.inetcat == inetcat.path, "the bundled forwarding tool comes first")
            #expect(
                (try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber)?
                    .intValue == 0o600
            )
            #expect(
                (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue
                    == 0o700
            )

            try publish(second, "127.0.0.1:4020", "second-device")
            DeveloperConnectionProfile.retire(instance: instance, session: first, state: state)
            let current = try read()
            #expect(
                current.session == second && current.usbmux == "127.0.0.1:4020",
                "a stale boot retired the current profile"
            )
            DeveloperConnectionProfile.retire(instance: instance, session: second, state: state)
            #expect(!FileManager.default.fileExists(atPath: profile.path))
        }
    }
}
