// The machines as LightTouchDevice's machines launch reports them (tests/fixtures/machines.json), set before a board's facts are read.
import Foundation
import HostRuntime

let fixtureMachines: Void = {
    let url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("../../../fixtures/machines.json").standardizedFileURL
    Machines.set(try! JSONDecoder().decode([DeviceInfo].self, from: Data(contentsOf: url)))
}()
