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

/// How the running device is shown on this phone.
enum ViewMode: String, CaseIterable {
    case bezel      // the device around the screen (the shell photo with the live screen inside)
    case plain      // a thin-border screen on the dark stage (matches the Mac app's plain view)
    case immersive  // the screen fills the phone; only the Home button is visible

    var title: String {
        switch self {
        case .bezel: return "With Device"
        case .plain: return "Plain Screen"
        case .immersive: return "Immersive"
        }
    }
    var symbol: String {
        switch self {
        case .bezel: return "iphone"
        case .plain: return "rectangle.on.rectangle.square"
        case .immersive: return "rectangle.expand.vertical"
        }
    }
}

/// The running screen, in whichever view mode is active. The bezel mode falls back to the plain stage when the build
/// has no art for this board, so a missing asset never leaves a black rectangle.
///
/// Pinch zooms the whole stage (and a two-finger drag pans while zoomed). Zoom resets to 1 when the user pinches back
/// past 1.0, so going "flat" is one gesture away.
struct DeviceStage: View {
    let board: Board?
    let qemu: QemuRuntime?
    let mode: ViewMode
    let keyboardBridge: UIView?
    let onHome: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        stage
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let proposed = lastScale * value
                        scale = min(max(proposed, 0.5), 4.0)
                    }
                    .onEnded { _ in
                        if scale < 1.05 {
                            withAnimation(.spring(duration: 0.3)) { scale = 1; offset = .zero }
                            lastScale = 1; lastOffset = .zero
                        } else { lastScale = scale }
                    }
                    // Two-finger drag at the same time as the pinch would be awkward — a simultaneous drag gesture
                    // with a minimum distance makes panning work only while the pinch isn't moving the scale.
                    .simultaneously(with: DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            // Only pan while zoomed in; a drag at 1.0 is usually a touch meant for the guest.
                            guard scale > 1.05 else { return }
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset })
            )
    }

    @ViewBuilder private var stage: some View {
        switch mode {
        case .bezel:
            if let art = board?.facts.art, let shell = UIImage(named: art.shell) {
                BezelView(art: art, shell: shell, qemu: qemu, keyboardBridge: keyboardBridge, onHome: onHome)
            } else {
                PlainStage(qemu: qemu, keyboardBridge: keyboardBridge)
            }
        case .plain:
            PlainStage(qemu: qemu, keyboardBridge: keyboardBridge)
        case .immersive:
            DisplayView(qemu: qemu, keyboardBridge: keyboardBridge)
                .ignoresSafeArea()
        }
    }
}

/// The plain view (IMG_7013 in the screenshots the user shared): a thin outlined rectangle for the screen, nothing
/// else. Takes whatever room it's given and shows the display aspect-fit inside it.
struct PlainStage: View {
    let qemu: QemuRuntime?
    let keyboardBridge: UIView?

    var body: some View {
        DisplayView(qemu: qemu, keyboardBridge: keyboardBridge)
            .padding(.horizontal, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    .padding(.horizontal, 10)
            )
    }
}

private struct BezelView: View {
    let art: Board.Art
    let shell: UIImage
    let qemu: QemuRuntime?
    let keyboardBridge: UIView?
    let onHome: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let pixels = art.shellPixels
            let scale = min(proxy.size.width / pixels.width, proxy.size.height / pixels.height)
            let cut = art.screenCutout
            let home = art.homeDiameter
            let width = pixels.width * scale
            let height = pixels.height * scale
            ZStack(alignment: .topLeading) {
                // The live screen sits inside the shell's cutout. It's drawn first, below the chrome, so the
                // bezel's rounded corners and chrome mask it instead of a white rectangle poking out at the edges.
                DisplayView(qemu: qemu, keyboardBridge: keyboardBridge)
                    .frame(width: cut.width * scale, height: cut.height * scale)
                    .offset(x: cut.minX * scale, y: cut.minY * scale)
                Image(uiImage: shell)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
                    .allowsHitTesting(false)   // the display underneath takes taps
                    .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
                // The Home button drawn on the shell IS the Home button.
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
            .frame(width: width, height: height, alignment: .topLeading)
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
