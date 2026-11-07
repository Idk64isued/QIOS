import Foundation
import Testing

@testable import HostServiceWire

/// Which AFC the Files browser's requests name (an app's container over the device's media folder or afc2), and the
/// edit and copy requests on the wire, each keeping its root.
struct FilesRequestTests {
    @Test func filesRequestsNameTheirRoot() throws {
        var services = DeviceServices(clientSocket: "/tmp/fixture")
        #expect(services.afcRoot == .media)
        services.wholeFileSystem = true
        #expect(services.afcRoot == .fileSystem)
        services.app = "com.example.Game"
        #expect(services.afcRoot == .app("com.example.Game"), "an app's container wins over the device's root")
        services.wholeFileSystem = false
        #expect(services.afcRoot == .app("com.example.Game"))

        let root = AFCRoot.app("com.example.Game")
        let file = DeviceFile(name: "a.sav", path: "Documents/a.sav", isDirectory: false, isRegular: true, size: 3)
        let operations: [HostServiceOperation] = [
            .files("Documents", root: root),
            .download(file, destination: "/tmp/a.sav", root: root),
            .upload(
                source: "/tmp/a.sav",
                remote: "Documents/a.sav",
                reuse: false,
                replace: true,
                allowEmpty: true,
                root: root
            ),
            .delete("Documents/Old", root: root),
            .rename("Documents/a.sav", to: "b.sav", root: root),
            .makeFolder("Documents/Mods", root: .fileSystem),
            .crashReports(copyTo: nil),
            .crashReports(copyTo: "/tmp/crash")
        ]
        for operation in operations {
            let request = HostServiceRequest(id: UUID(), session: UUID(), operation: operation)
            let decoded = try JSONDecoder().decode(HostServiceRequest.self, from: JSONEncoder().encode(request))
            #expect(decoded.version == 6 && "\(decoded.operation)" == "\(operation)")
        }
    }
}
