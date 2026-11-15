import SwiftUI

/// The device's screen as every view mode shows it: the live display, turned to match the device's orientation, and
/// what it looks like when the device has switched its own screen off.
///
/// Rotation is presentational. The device's framebuffer is portrait, always, exactly as a real iPhone's panel is;
/// when the device is turned, iOS draws its interface sideways inside that portrait buffer. A real phone looks right
/// because you turned the phone. Here, the app turns the picture instead. Touches still land correctly because the
/// display maps them in its own, unturned coordinates, which are the framebuffer's.
struct GuestScreen: View {
    let qemu: QemuRuntime?
    let keyboardBridge: UIView?
    @EnvironmentObject private var controls: DeviceControls

    var body: some View {
        DisplayView(qemu: qemu, keyboardBridge: keyboardBridge)
            .overlay {
                if controls.screenAsleep {
                    SleepOverlay { controls.wakeScreen() }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: controls.screenAsleep)
    }
}

/// Turns its content a number of quarter turns clockwise and lays it out in the space the turned content actually
/// takes, so a device turned on its side fits the width rather than overflowing it.
struct QuarterTurned<Content: View>: View {
    let turns: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let sideways = turns % 2 != 0
            content()
                .frame(
                    width: sideways ? proxy.size.height : proxy.size.width,
                    height: sideways ? proxy.size.width : proxy.size.height)
                .rotationEffect(.degrees(Double(turns) * 90))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.spring(duration: 0.45), value: turns)
    }
}

/// The screen while the device sleeps: dark, as the real panel would be, with a slow drift of z's so it reads as
/// asleep rather than broken. A tap presses Sleep / Wake.
struct SleepOverlay: View {
    let onWake: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
            VStack(spacing: 14) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        Text("\u{1F4A4}")   // 💤
                            .font(.system(size: 46))
                            .offset(y: CGFloat(sin(t * 1.6)) * 4)
                            .opacity(0.9)
                        // Three z's leaving the sleeper, staggered, rising and fading.
                        ForEach(0..<3, id: \.self) { index in
                            let progress = ((t / 2.6) + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                            Text("z")
                                .font(.system(size: 13 + CGFloat(index) * 5, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .opacity(sin(progress * .pi) * 0.85)
                                .offset(x: 26 + CGFloat(progress) * 26, y: -14 - CGFloat(progress) * 46)
                        }
                    }
                    .frame(width: 140, height: 110)
                }
                Text("Asleep")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Tap to wake")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onWake()
        }
    }
}
