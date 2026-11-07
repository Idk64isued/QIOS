// A machine as the emulator describes it: libqemu-arm.dylib's qemu_ios_device_info (qemu-ios
// contrib/ios-app/qemu-ios-ui.h). The helper reports it in its hello and lists every machine with
// `LightTouchDevice '{"mode":{"machines":{}}}'`; nothing on this side keeps a copy.

import CoreGraphics
import Foundation

public struct DeviceInfo: Codable, Sendable, Equatable {
    /// The -M name.
    public var machine: String
    public var board: String
    /// Framebuffer pixels as the panel scans them out, at defaultOrientation (0 portrait, 1 landscape).
    public var screenWidth: Int
    public var screenHeight: Int
    public var screenScale: Int
    public var defaultOrientation: Int
    /// A modem (ios-baseband): the Carrier panel; the A4/S5L8920 machines take baseband=on and its cell0 netdev.
    public var hasCellular: Bool
    /// usb-bus.0: the USB keyboard, which can be unplugged and plugged back while running.
    public var hasUSBHost: Bool
    public var hasCompass: Bool
    /// What panel=WxH accepts, as the panel scans: sides >= panelMin, the width a multiple of panelWidthStep, at most
    /// panelMaxPixels pixels (0: no bound beyond the sides).
    public var panelMin: Int
    public var panelMaxWidth: Int
    public var panelMaxHeight: Int
    public var panelWidthStep: Int
    public var panelMaxPixels: Int

    public init(
        machine: String,
        board: String,
        screenWidth: Int,
        screenHeight: Int,
        screenScale: Int,
        defaultOrientation: Int,
        hasCellular: Bool,
        hasUSBHost: Bool,
        hasCompass: Bool,
        panelMin: Int,
        panelMaxWidth: Int,
        panelMaxHeight: Int,
        panelWidthStep: Int,
        panelMaxPixels: Int
    ) {
        self.machine = machine
        self.board = board
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenScale = screenScale
        self.defaultOrientation = defaultOrientation
        self.hasCellular = hasCellular
        self.hasUSBHost = hasUSBHost
        self.hasCompass = hasCompass
        self.panelMin = panelMin
        self.panelMaxWidth = panelMaxWidth
        self.panelMaxHeight = panelMaxHeight
        self.panelWidthStep = panelWidthStep
        self.panelMaxPixels = panelMaxPixels
    }

    public var screenPixels: CGSize { CGSize(width: screenWidth, height: screenHeight) }

    /// Every machine `helper` (LightTouchDevice) runs: its machines launch ({"dylibPath", "machines"}).
    public static func list(helper: URL) throws -> [DeviceInfo] {
        let process = Process()
        process.executableURL = helper
        process.arguments = HelperLaunch(.machines).arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        // A sandboxed helper's emulator, granted on its standard input once it runs (as firmwarekit's one-shots)
        let grants = HelperSandbox.isSandboxed(helper) ? Pipe() : nil
        process.standardInput = grants ?? FileHandle.nullDevice
        try process.run()
        if let grants {
            let (tokens, _) = SandboxExtension.issue(
                HelperSandbox.emulatorGrants(helper: helper),
                to: .pid(process.processIdentifier)
            )
            try? grants.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(tokens))
            try? grants.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(
                .executableLoad,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(helper.lastPathComponent) machines exited \(process.terminationStatus)"
                ]
            )
        }
        struct Listing: Decodable { let machines: [DeviceInfo] }
        return try JSONDecoder().decode(Listing.self, from: data).machines
    }
}

/// The emulator's machines by board, for this process: listed once from the helper `Machines.helper` names (the
/// app's bundled LightTouchDevice, firmwarekit's --helper), or set outright (a helper's hello, tests).
public enum Machines {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [Board: DeviceInfo]?
    nonisolated(unsafe) private static var source: URL?

    /// The helper to list from; set before the first lookup.
    public static var helper: URL? {
        get { lock.withLock { source } }
        set {
            lock.withLock {
                source = newValue
                table = nil
            }
        }
    }

    public static func set(_ machines: [DeviceInfo]) {
        lock.withLock { table = index(machines) }
    }

    /// One machine's facts; nil when the helper can't list them (no emulator library), or for a board it lacks.
    public static subscript(board: Board) -> DeviceInfo? {
        lock.withLock {
            if table == nil, let source {
                do { table = index(try DeviceInfo.list(helper: source)) } catch {
                    table = [:]
                    FileHandle.standardError.write(Data("machines: \(error.localizedDescription)\n".utf8))
                }
            }
            return table?[board]
        }
    }

    private static func index(_ machines: [DeviceInfo]) -> [Board: DeviceInfo] {
        Dictionary(machines.compactMap { info in Board(rawValue: info.board).map { ($0, info) } }) { first, _ in first }
    }
}

extension Board {
    /// The emulator's facts about this board (Machines).
    public var hardware: DeviceInfo? { Machines[self] }
}
