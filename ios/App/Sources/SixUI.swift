import SwiftUI
import UIKit

// MARK: - The iOS 6 look

/// The home screen's interface (Settings › Home Screen): the original layout drawn as iOS 6's grouped tables, or the
/// original glass look.
enum HomeInterface: String, CaseIterable, Identifiable {
    case classic, modern
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Original (iOS 6)"
        case .modern: return "Original (Glass)"
        }
    }
    var detail: String {
        switch self {
        case .classic: return "The original list, drawn like iOS 6\u{2019}s Settings."
        case .modern: return "The original list in Light Touch\u{2019}s glass look."
        }
    }
}

/// iOS 6's colours, each with a dark version. iOS 6 never had a dark mode, so the dark one is what it would have
/// been: the black glossy bars it used for media apps, slate pinstripes, charcoal cells, the same blue for what's
/// selected. Both follow Settings › Appearance (or the phone's own setting) like the rest of the app.
enum Six {
    private static func c(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        Theme.adaptive(light: ui(light, la), dark: ui(dark, da))
    }
    static func ui(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }

    // The navigation bar: blue-grey glass in light, black glass in dark.
    static let navTop = c(0xB0BCCD, 0x5A5C62)
    static let navMid = c(0x8195AF, 0x2C2D31)
    static let navBottom = c(0x6D83A1, 0x0E0F11)
    static let navLine = c(0x2D3642, 0x000000)
    static let navButtonTop = c(0x8EA2BD, 0x5C5E64)
    static let navButtonBottom = c(0x4D6789, 0x202125)
    static let navButtonBorder = c(0x3A4C66, 0x000000)
    static let doneTop = c(0x7AA2E8, 0x6E9AE6)
    static let doneBottom = c(0x2F67D0, 0x2457BA)

    // The grouped table: pinstripes behind rounded white cells.
    static let stripeBase = c(0xC5CCD4, 0x18191D)
    static let stripeLine = c(0xCBD2D8, 0x1D1E23)
    static let cell = c(0xFFFFFF, 0x2A2C31)
    static let cellPressed = c(0x1A7CF0, 0x1A6CD8)
    static let cellBorder = c(0xABABAB, 0x0B0C0E)
    static let cellSeparator = c(0xE0E0E0, 0x3A3C42)
    static let text = c(0x000000, 0xFFFFFF)
    static let detail = c(0x385487, 0x8FA6C8)
    static let subtle = c(0x7A7A7A, 0x9A9EA6)
    static let chevron = c(0x8A8A8A, 0x6E727A)
    static let header = c(0x4C566C, 0xA3AAB6)
    static let headerShadow = c(0xFFFFFF, 0x000000, 1, 0.9)
    static let blue = c(0x2F6BD8, 0x5A93F0)
    static let red = c(0xC8281E, 0xF0675C)
    static let green = c(0x3D9A2B, 0x6CC955)

    // Switches and segments.
    static let onTop = c(0x1F5ED6, 0x2A66D2)
    static let onBottom = c(0x5CA1F5, 0x4F8EE6)
    static let offTop = c(0xEDEDED, 0x4A4C52)
    static let offBottom = c(0xFFFFFF, 0x34363B)
    static let offText = c(0x808080, 0xB4B8BF)
    static let segTop = c(0xFFFFFF, 0x45474D)
    static let segBottom = c(0xDCDCDC, 0x2D2F34)
    static let segSelTop = c(0x2A5CAA, 0x2B5BB0)
    static let segSelBottom = c(0x6893D8, 0x5B88D6)
    static let segBorder = c(0x8E8E8E, 0x0E0F11)

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Helvetica-Bold" : "Helvetica", size: size)
    }

    /// The bar's gloss: the gradient, a lighter top half over it.
    struct BarBackground: View {
        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [navTop, navMid, navBottom], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
            }
        }
    }

    /// Vertical pinstripes, the grouped table's background.
    struct Pinstripes: View {
        var body: some View {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(stripeBase))
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 3, height: size.height)), with: .color(stripeLine))
                    x += 7
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// The iOS 6 screens drawn in the glass look instead (Settings › Home Screen › Original (Glass)): the same pages, on
/// Light Touch's gradient with frosted cards, plain bars and the system's switches. The Setup Assistant uses it.
private struct GlassStyleKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var glassStyle: Bool {
        get { self[GlassStyleKey.self] }
        set { self[GlassStyleKey.self] = newValue }
    }
}

/// A bar button: bordered glossy rounded rectangle; `done` is the blue one.
struct SixBarButton: View {
    let title: String
    var done = false
    var back = false
    let action: () -> Void
    @Environment(\.glassStyle) private var glass

    var body: some View {
        if glass {
            Button(action: action) {
                HStack(spacing: 3) {
                    if back { Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)) }
                    Text(title).font(.system(size: 16, weight: done ? .semibold : .regular, design: .rounded))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
                .frame(height: 30)
            }
            .buttonStyle(.plain)
        } else {
            sixButton
        }
    }

    @ViewBuilder private var sixButton: some View {
        Button(action: action) {
            Text(title)
                .font(Six.font(12, bold: true))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 0, y: -1)
                .padding(.leading, back ? 14 : 10)
                .padding(.trailing, 10)
                .frame(height: 30)
                .background(SixBackShape(pointed: back).fill(LinearGradient(colors: done ? [Six.doneTop, Six.doneBottom] : [Six.navButtonTop, Six.navButtonBottom],
                                                      startPoint: .top, endPoint: .bottom)))
                .overlay(SixBackShape(pointed: back).stroke(Six.navButtonBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A rounded rectangle, or with `pointed` the back button's arrow on the left.
struct SixBackShape: Shape {
    var pointed: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 5
        guard pointed else { return Path(roundedRect: rect, cornerRadius: r, style: .continuous) }
        var p = Path()
        let tip: CGFloat = 11
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX + tip, y: rect.minY + 1))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + tip, y: rect.maxY - 1))
        p.closeSubpath()
        return p
    }
}

/// The navigation bar with an embossed title.
struct SixNavBar: View {
    let title: String
    var left: (String, () -> Void)? = nil
    var leftIsBack = false
    var right: (String, () -> Void)? = nil
    @Environment(\.glassStyle) private var glass

    var body: some View {
        if glass {
            bar
                .background(Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .top))
                .overlay(alignment: .bottom) { Theme.cardBorder.frame(height: 0.5) }
        } else {
            bar
                .background(Six.BarBackground().ignoresSafeArea(edges: .top))
                .overlay(alignment: .bottom) { Six.navLine.frame(height: 1) }
        }
    }

    private var bar: some View {
        ZStack {
            Text(title)
                .font(glass ? .system(size: 17, weight: .semibold, design: .rounded) : Six.font(20, bold: true))
                .foregroundStyle(glass ? Theme.primaryText : Color.white)
                .shadow(color: glass ? .clear : .black.opacity(0.5), radius: 0, y: -1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 90)
            HStack {
                if let left { SixBarButton(title: left.0, back: leftIsBack, action: left.1) }
                Spacer()
                if let right { SixBarButton(title: right.0, done: true, action: right.1) }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
    }
}

/// A screen of grouped sections on pinstripes, under a navigation bar.
struct SixScreen<Content: View>: View {
    let title: String
    var left: (String, () -> Void)? = nil
    var leftIsBack = false
    var right: (String, () -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.glassStyle) private var glass

    var body: some View {
        VStack(spacing: 0) {
            SixNavBar(title: title, left: left, leftIsBack: leftIsBack, right: right)
            ScrollView {
                VStack(spacing: 0) { content() }
                    .padding(.horizontal, glass ? 16 : 10)
                    .padding(.bottom, 24)
            }
        }
        .background {
            if glass { LTBackground() } else { Six.Pinstripes() }
        }
    }
}

/// A grouped section: an embossed header, rows in one rounded cell, a footer.
struct SixSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.glassStyle) private var glass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                if glass {
                    Text(header)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.primaryText.opacity(0.7))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 8)
                } else {
                    Text(header)
                        .font(Six.font(17, bold: true))
                        .foregroundStyle(Six.header)
                        .shadow(color: Six.headerShadow, radius: 0, y: 1)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 7)
                }
            }
            if glass {
                VStack(spacing: 0) { content() }
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.cardBorder, lineWidth: 0.5))
                    .shadow(color: Theme.shadow, radius: 12, y: 6)
            } else {
                VStack(spacing: 0) { content() }
                    .background(Six.cell)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Six.cellBorder, lineWidth: 1))
                    .shadow(color: Six.headerShadow.opacity(0.6), radius: 0, y: 1)
            }
            if let footer {
                Text(footer)
                    .font(glass ? .system(size: 12, design: .rounded) : Six.font(14))
                    .foregroundStyle(glass ? Theme.secondaryText : Six.header)
                    .shadow(color: glass ? .clear : Six.headerShadow, radius: 0, y: 1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
        }
        .padding(.top, 20)
    }
}

/// The line between rows in a section.
struct SixSeparator: View {
    @Environment(\.glassStyle) private var glass
    var body: some View {
        if glass { Theme.ink.opacity(0.08).frame(height: 0.5) } else { Six.cellSeparator.frame(height: 1) }
    }
}

/// A small rounded icon of the time: a symbol on a glossy coloured square.
struct SixIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 29

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 0, y: -1))
            .overlay(alignment: .top) {
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 1.5, height: size * 0.85)
                    .offset(y: -size * 0.36)
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
    }
}

/// A row: optional icon, title, a value on the right, and a chevron when it opens something.
struct SixRow: View {
    var icon: AnyView? = nil
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var chevron = true
    var checked = false
    var titleColor: Color? = nil
    var centered = false
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(SixRowPress())
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            if let icon { icon }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Six.font(17, bold: true))
                    .foregroundStyle(titleColor ?? Six.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let subtitle {
                    Text(subtitle).font(Six.font(13)).foregroundStyle(Six.subtle).lineLimit(2)
                }
            }
            .frame(maxWidth: centered ? .infinity : nil, alignment: centered ? .center : .leading)
            if !centered { Spacer(minLength: 6) }
            if let value {
                Text(value).font(Six.font(17)).foregroundStyle(Six.detail).lineLimit(1)
            }
            if checked {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Six.detail)
            } else if chevron && action != nil {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Six.chevron)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .padding(.vertical, subtitle == nil ? 0 : 6)
        .contentShape(Rectangle())
    }
}

/// A row's highlight while it's held: a wash of the time's selection blue.
struct SixRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Six.cellPressed.opacity(0.28) : Color.clear)
    }
}

/// A row with iOS 6's ON/OFF switch.
struct SixToggleRow: View {
    var icon: AnyView? = nil
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let icon { icon }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Six.font(16, bold: true)).foregroundStyle(Six.text).lineLimit(2).minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle).font(Six.font(12)).foregroundStyle(Six.subtle).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            SixSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .padding(.vertical, subtitle == nil ? 0 : 6)
    }
}

/// iOS 5/6's switch: a capsule with ON in blue or OFF in grey, a white knob.
struct SixSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.glassStyle) private var glass

    var body: some View {
        if glass {
            Toggle("", isOn: $isOn).labelsHidden().tint(Theme.accent)
        } else {
            sixSwitch
        }
    }

    @ViewBuilder private var sixSwitch: some View {
        let width: CGFloat = 77
        let height: CGFloat = 27
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(LinearGradient(colors: isOn ? [Six.onTop, Six.onBottom] : [Six.offTop, Six.offBottom],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Text(isOn ? "ON" : "OFF")
                        .font(Six.font(16, bold: true))
                        .foregroundStyle(isOn ? Color.white : Six.offText)
                        .shadow(color: isOn ? .black.opacity(0.3) : .clear, radius: 0, y: -1)
                        .offset(x: isOn ? -14 : 14))
                .overlay(Capsule().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .overlay(Capsule().stroke(Color.black.opacity(0.18), lineWidth: 3).blur(radius: 1.5).clipShape(Capsule()))
            Circle()
                .fill(LinearGradient(colors: [Six.ui(0xCDCDCD).swiftUI, .white], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .frame(width: height, height: height)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .frame(width: width, height: height)
        .contentShape(Capsule())
        .onTapGesture {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.18)) { isOn.toggle() }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

extension UIColor {
    var swiftUI: Color { Color(self) }
}

/// iOS 6's bordered segmented control.
struct SixSegments<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @Environment(\.glassStyle) private var glass

    var body: some View {
        if glass {
            Picker("", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.segmented)
        } else {
            sixSegments
        }
    }

    @ViewBuilder private var sixSegments: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(Six.font(13, bold: true))
                        .foregroundStyle(selected ? Color.white : Six.header)
                        .shadow(color: selected ? .black.opacity(0.35) : Six.headerShadow, radius: 0, y: selected ? -1 : 1)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(LinearGradient(colors: selected ? [Six.segSelTop, Six.segSelBottom] : [Six.segTop, Six.segBottom],
                                                   startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .trailing) {
                            if index < options.count - 1 { Six.segBorder.frame(width: 1) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Six.segBorder, lineWidth: 1))
    }
}

/// A big glossy button of the time (the Setup Assistant's Next, a Delete).
struct SixBigButton: View {
    let title: String
    var colors: [Color] = [Six.ui(0x6FA0F0).swiftUI, Six.ui(0x2A62CF).swiftUI]
    /// A grey button (Cancel, Later): in the glass look, tinted rather than filled.
    var secondary = false
    var enabled = true
    let action: () -> Void
    @Environment(\.glassStyle) private var glass

    var body: some View {
        if glass {
            let primary = !secondary
            Button(action: action) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(primary ? Theme.onAccent : Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(primary ? Theme.accent : Theme.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        } else {
            sixButton
        }
    }

    @ViewBuilder private var sixButton: some View {
        Button(action: action) {
            Text(title)
                .font(Six.font(18, bold: true))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 0, y: -1)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    ZStack(alignment: .top) {
                        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 23)
                    })
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.black.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// What a home screen can do, handed to whichever interface is showing (RootView owns the state and the sheets).
struct HomeActions {
    let boot: (DeviceFolder) -> Void
    let erase: (DeviceFolder) -> Void
    let addDevice: () -> Void
    let store: () -> Void
    let storage: () -> Void
    let settings: () -> Void
    let allSettings: () -> Void
    let console: () -> Void
    let report: () -> Void
    let exportLog: () -> Void
    let clearLog: () -> Void
    /// Shows the changelog (Main menu > What's New), and opens by itself after an update.
    let whatsNew: () -> Void
}
