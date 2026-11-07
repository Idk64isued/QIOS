import Foundation
import Testing

@testable import HostServiceClient
@testable import HostServiceWire

/// A copy of the device's bytes reaches its name on the Mac already marked as Light Touch's download, read back from
/// the file itself. The services helper here is a script that writes the bytes where the request says.
struct QuarantineTests {
    static let worker = """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]*)".*/\\1/')
          session=$(printf '%s' "$line" | sed -E 's/.*"session":"([^"]*)".*/\\1/')
          dest=$(printf '%s' "$line" | sed -E 's/.*"destination":"([^"]*)".*/\\1/; s|\\\\/|/|g')
          printf 'PK' > "$dest"
          printf '{"id":"%s","session":"%s","payload":{"result":{"_0":{"none":{}}}}}\\n' "$id" "$session"
        done
        """

    @Test func aDownloadIsQuarantined() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ltm-quarantine-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("worker")
        try Data(Self.worker.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("LTM_HOST_SERVICE_WORKER", script.path, 1)
        defer { unsetenv("LTM_HOST_SERVICE_WORKER") }
        for (index, root) in [nil, "com.example.Game"].enumerated() {
            var services = DeviceServices(clientSocket: folder.appendingPathComponent("usbmuxd").path, session: UUID())
            services.app = root
            let file = DeviceFile(
                name: "a b.zip",
                path: "Downloads/a b.zip",
                isDirectory: false,
                isRegular: true,
                size: 2
            )
            let saved = folder.appendingPathComponent("a b \(index).zip")
            try await services.download(file, to: saved) { _ in }
            await services.stopWorker()
            #expect(try String(contentsOf: saved, encoding: .utf8) == "PK")
            #expect(getxattr(saved.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "no com.apple.quarantine")
            let properties = try #require(
                try saved.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            )
            #expect(properties["LSQuarantineAgentName"] as? String == "Light Touch")
            #expect(properties["LSQuarantineType"] as? String == "LSQuarantineTypeOtherDownload")
        }
    }
}
