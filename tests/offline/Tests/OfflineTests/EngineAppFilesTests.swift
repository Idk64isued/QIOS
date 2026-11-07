import CIMobileDevice
import Foundation
import HostServiceWire
import Testing

@testable import Engine

extension SharedState {
    /// The Files browser's app containers and edits in the services engine (LightTouchServices/Engine/AFC.swift) over
    /// the fake libimobiledevice: an app's AFC is house_arrest's VendContainer for its bundle ID, its refusal named and
    /// its client freed after the AFC client; delete takes a folder with everything in it; rename and new folder leave
    /// an existing item alone.
    @Suite struct EngineAppFilesTests {
        final class Trace: @unchecked Sendable { var calls: [String] = [] }

        @Test func appContainerThroughHouseArrest() throws {
            let saved = (
                IMDFake.lockdownStartService, IMDFake.houseArrestClientNew, IMDFake.houseArrestClientFree,
                IMDFake.houseArrestSendCommand, IMDFake.houseArrestGetResult, IMDFake.afcClientFromHouseArrest,
                IMDFake.afcClientFree
            )
            defer {
                (
                    IMDFake.lockdownStartService, IMDFake.houseArrestClientNew, IMDFake.houseArrestClientFree,
                    IMDFake.houseArrestSendCommand, IMDFake.houseArrestGetResult, IMDFake.afcClientFromHouseArrest,
                    IMDFake.afcClientFree
                ) = saved
            }
            let t = Trace()
            let arrest = OpaquePointer(bitPattern: 0x40)!
            let afc = OpaquePointer(bitPattern: 0x50)!
            var reply: [String: Any] = ["Status": "Complete"]
            IMDFake.lockdownStartService = { _, name, out in
                t.calls.append("start " + String(cString: name!))
                out?.pointee = UnsafeMutablePointer(bitPattern: 0x20)
                return LOCKDOWN_E_SUCCESS
            }
            IMDFake.houseArrestClientNew = { _, _, out in
                out?.pointee = arrest
                return HOUSE_ARREST_E_SUCCESS
            }
            IMDFake.houseArrestSendCommand = { c, command, id in
                #expect(c == arrest)
                t.calls.append(String(cString: command!) + " " + String(cString: id!))
                return HOUSE_ARREST_E_SUCCESS
            }
            IMDFake.houseArrestGetResult = { _, out in
                out?.pointee = IMDFake.node(reply)
                return HOUSE_ARREST_E_SUCCESS
            }
            IMDFake.afcClientFromHouseArrest = { c, out in
                #expect(c == arrest)
                out?.pointee = afc
                return AFC_E_SUCCESS
            }
            IMDFake.houseArrestClientFree = { c in
                #expect(c == arrest)
                t.calls.append("free house_arrest")
                return HOUSE_ARREST_E_SUCCESS
            }
            IMDFake.afcClientFree = { c in
                #expect(c == afc)
                t.calls.append("free afc")
                return AFC_E_SUCCESS
            }
            let device = OpaquePointer(bitPattern: 17)!
            let opened = try IMobileDevice.startAFC(device: device, root: .app("com.example.Game"))
            #expect(opened.client == afc)
            opened.close()
            #expect(
                t.calls == [
                    "start com.apple.mobile.house_arrest", "VendContainer com.example.Game", "free afc",
                    "free house_arrest"
                ],
                "\(t.calls)"
            )
            t.calls = []
            reply = ["Error": "ApplicationLookupFailed"]
            do {
                _ = try IMobileDevice.startAFC(device: device, root: .app("com.example.Gone"))
                Issue.record("a refused app opened")
            } catch {
                #expect(error.localizedDescription.contains("ApplicationLookupFailed"), "\(error)")
            }
            #expect(t.calls.last == "free house_arrest" && !t.calls.contains("free afc"), "\(t.calls)")
            t.calls = []
            _ = try? IMobileDevice.startAFC(device: device, root: .fileSystem)  // afc_client_new answers an error here
            #expect(t.calls == ["start com.apple.afc2"])
        }

        /// A device tree the AFC fakes serve: folders hold names, files hold nothing.
        final class Tree: @unchecked Sendable {
            var folders: [String: [String]] = [:]
            var files: Set<String> = []
            func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
            func exists(_ path: String) -> Bool { folders[path] != nil || files.contains(path) }
            func detach(_ path: String) {
                folders[parent(path)]?.removeAll { $0 == (path as NSString).lastPathComponent }
            }
        }

        @Test func editsInAnAppContainer() async throws {
            let saved = (
                IMDFake.ideviceNew, IMDFake.lockdownStartService, IMDFake.houseArrestClientNew,
                IMDFake.houseArrestSendCommand, IMDFake.houseArrestGetResult, IMDFake.afcClientFromHouseArrest,
                IMDFake.afcRemovePath, IMDFake.afcReadDirectory, IMDFake.afcFileInfo, IMDFake.afcRenamePath,
                IMDFake.afcMakeDirectory
            )
            defer {
                (
                    IMDFake.ideviceNew, IMDFake.lockdownStartService, IMDFake.houseArrestClientNew,
                    IMDFake.houseArrestSendCommand, IMDFake.houseArrestGetResult, IMDFake.afcClientFromHouseArrest,
                    IMDFake.afcRemovePath, IMDFake.afcReadDirectory, IMDFake.afcFileInfo, IMDFake.afcRenamePath,
                    IMDFake.afcMakeDirectory
                ) = saved
            }
            Attachment.install()
            IMDFake.lockdownStartService = { _, _, out in
                out?.pointee = UnsafeMutablePointer(bitPattern: 0x20)
                return LOCKDOWN_E_SUCCESS
            }
            IMDFake.houseArrestClientNew = { _, _, out in
                out?.pointee = OpaquePointer(bitPattern: 0x40)
                return HOUSE_ARREST_E_SUCCESS
            }
            IMDFake.houseArrestSendCommand = { _, _, _ in HOUSE_ARREST_E_SUCCESS }
            IMDFake.houseArrestGetResult = { _, out in
                out?.pointee = IMDFake.node(["Status": "Complete"])
                return HOUSE_ARREST_E_SUCCESS
            }
            IMDFake.afcClientFromHouseArrest = { _, out in
                out?.pointee = OpaquePointer(bitPattern: 0x50)
                return AFC_E_SUCCESS
            }
            let tree = Tree()
            tree.folders = [
                "Documents": ["Saves", "a.txt"], "Documents/Saves": ["1.sav", "Old"], "Documents/Saves/Old": ["0.sav"]
            ]
            tree.files = ["Documents/a.txt", "Documents/Saves/1.sav", "Documents/Saves/Old/0.sav"]
            func strings(_ list: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
                let out = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: list.count + 1)
                for (i, s) in list.enumerated() { out[i] = strdup(s) }
                out[list.count] = nil
                return out
            }
            IMDFake.afcRemovePath = { _, p in
                let path = String(cString: p!)
                if tree.files.remove(path) != nil {
                    tree.detach(path)
                    return AFC_E_SUCCESS
                }
                guard let children = tree.folders[path] else { return AFC_E_OBJECT_NOT_FOUND }
                guard children.isEmpty else { return AFC_E_DIR_NOT_EMPTY }
                tree.folders[path] = nil
                tree.detach(path)
                return AFC_E_SUCCESS
            }
            IMDFake.afcReadDirectory = { _, p, out in
                guard let children = tree.folders[String(cString: p!)] else { return AFC_E_OBJECT_NOT_FOUND }
                out?.pointee = strings([".", ".."] + children)
                return AFC_E_SUCCESS
            }
            IMDFake.afcFileInfo = { _, p, out in
                let path = String(cString: p!)
                guard tree.exists(path) else { return AFC_E_OBJECT_NOT_FOUND }
                out?.pointee = strings(["st_ifmt", tree.files.contains(path) ? "S_IFREG" : "S_IFDIR"])
                return AFC_E_SUCCESS
            }
            IMDFake.afcRenamePath = { _, f, to in
                let (from, target) = (String(cString: f!), String(cString: to!))
                guard tree.files.remove(from) != nil else { return AFC_E_OBJECT_NOT_FOUND }
                tree.detach(from)
                tree.files.insert(target)
                tree.folders[tree.parent(target), default: []].append((target as NSString).lastPathComponent)
                return AFC_E_SUCCESS
            }
            IMDFake.afcMakeDirectory = { _, p in
                let path = String(cString: p!)
                tree.folders[path] = []
                tree.folders[tree.parent(path), default: []].append((path as NSString).lastPathComponent)
                return AFC_E_SUCCESS
            }
            let device = DeviceServices(clientSocket: "fixture")
            let root = AFCRoot.app("com.example.Game")

            try await device.delete("Documents/Saves", root: root)
            #expect(tree.folders["Documents"] == ["a.txt"] && tree.files == ["Documents/a.txt"], "\(tree.folders)")

            try await device.makeFolder("Documents/Mods", root: root)
            #expect(tree.folders["Documents/Mods"] == [])
            do {
                try await device.makeFolder("Documents/Mods", root: root)
                Issue.record("a second Mods folder")
            } catch DeviceError.preflight(let message) { #expect(message.contains("“Mods”")) }

            try await device.rename("Documents/a.txt", to: "b.txt", root: root)
            #expect(tree.files == ["Documents/b.txt"])
            tree.files.insert("Documents/c.txt")
            do {
                try await device.rename("Documents/b.txt", to: "c.txt", root: root)
                Issue.record("renamed over c.txt")
            } catch DeviceError.preflight(let message) { #expect(message.contains("“c.txt”")) }
            #expect(tree.files == ["Documents/b.txt", "Documents/c.txt"])
            for bad in ["", "x/y"] {
                do {
                    try await device.rename("Documents/b.txt", to: bad, root: root)
                    Issue.record("renamed to \(bad)")
                } catch DeviceError.preflight {}
            }
        }
    }
}
