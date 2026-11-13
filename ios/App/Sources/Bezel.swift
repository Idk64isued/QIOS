import HostRuntime
import SwiftUI
import UIKit

// The device around the screen. The art and its measurements are the Mac app's (LightTouchMac/Assets.xcassets and
// HostRuntime's Board.facts.art): the shell picture, where the screen sits in it, where the Home button is.

extension DeviceFolder {
    struct Details {
        var board: Board?
        var version: String?
        var build: String?
    }

    /// What the device's lock says it is (base/device.lock.json).
    var details: Details {
        let lock = url.appendingPathComponent("base/device.lock.json")
        guard let data = try? Data(contentsOf: lock),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Details() }
        return Details(
            board: (json["board"] as? String).flatMap { Board(rawValue: $0) },
            version: json["product_version"] as? String,
            build: json["build"] as? String)
    }

    var model: DeviceModel? { details.board.map { DeviceModel(board: $0.rawValue) } }

    /// "iPod touch 2G · iPhone OS 3.1.3"
    var subtitle: String {
        let d = details
        var parts: [String] = []
        if let board = d.board { parts.append(DeviceModel(board: board.rawValue).shortName) }
        if let version = d.version {
            let major = Int(version.prefix { $0 != "." }) ?? 0
            parts.append((major < 4 ? "iPhone OS " : "iOS ") + version)
        }
        return parts.isEmpty ? "Prepared device" : parts.joined(separator: " \u{00B7} ")
    }
}

/// The flat picture of a device model, or its symbol when the build has no art for it.
struct DeviceThumbnail: View {
    let model: DeviceModel
    let height: CGFloat

    var body: some View {
        if let image = UIImage(named: model.shellImage) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .shadow(color: .black.opacity(0.5), radius: height / 14, y: height / 30)
        } else {
            Image(systemName: model.symbol)
                .font(.system(size: height * 0.6, weight: .thin))
                .foregroundStyle(.white.opacity(0.8))
                .frame(height: height)
        }
    }
}

/// The running screen, inside its device when `bezel` is on and the art is there, else on its own.
struct DeviceStage: View {
    let board: Board?
    let qemu: QemuRuntime?
    let bezel: Bool
    let onHome: () -> Void

    var body: some View {
        if bezel, let art = board?.facts.art, let shell = UIImage(named: art.shell) {
            BezelView(art: art, shell: shell, qemu: qemu, onHome: onHome)
        } else {
            DisplayView(qemu: qemu)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                .padding(.horizontal, 12)
        }
    }
}

private struct BezelView: View {
    let art: Board.Art
    let shell: UIImage
    let qemu: QemuRuntime?
    let onHome: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let pixels = art.shellPixels
            let scale = min(proxy.size.width / pixels.width, proxy.size.height / pixels.height)
            let cut = art.screenCutout
            let home = art.homeDiameter
            ZStack(alignment: .topLeading) {
                Image(uiImage: shell)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: pixels.width * scale, height: pixels.height * scale)
                    .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
                DisplayView(qemu: qemu)
                    .frame(width: cut.width * scale, height: cut.height * scale)
                    .offset(x: cut.minX * scale, y: cut.minY * scale)
                // The Home button drawn on the shell is the Home button.
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onHome()
                } label: {
                    Circle().fill(Color.white.opacity(0.001))
                }
                .buttonStyle(.plain)
                .frame(width: home * scale, height: home * scale)
                .offset(x: (pixels.width - home) / 2 * scale, y: (pixels.height - art.homeBottomInset - home) * scale)
            }
            .frame(width: pixels.width * scale, height: pixels.height * scale, alignment: .topLeading)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

extension DeviceFolder {
    /// What the Legacy Store should judge apps for when this device is the one running.
    var storeTarget: StoreTarget {
        let d = details
        guard let board = d.board else { return StoreTarget() }
        return StoreTarget(
            productType: board.facts.productType,
            os: d.version ?? "3.1.3",
            arch: ["n72ap", "n45ap", "m68ap"].contains(board.rawValue) ? "armv6" : "armv7",
            name: DeviceModel(board: board.rawValue).shortName)
    }
}
