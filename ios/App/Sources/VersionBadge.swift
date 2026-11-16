import SwiftUI

/// A firmware's badge in the version lists (the Setup Assistant's Choose Software, and Add Device): a tile with the
/// major version and the system's name of the time ("iPhone OS" up to 3, "iOS" from 4), each major version in its own
/// colours, and a corner tag on a developer seed ("BETA 2", "GM"). Light Touch's own design, not Apple's artwork.
struct VersionBadge: View {
    let firmware: CatalogFirmware
    var size: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        let style = Self.style(firmware.major)
        ZStack {
            LinearGradient(colors: style.colors, startPoint: .top, endPoint: .bottom)
            VStack(spacing: -size * 0.04) {
                Text(firmware.major < 4 ? "iPhone OS" : "iOS")
                    .font(.system(size: size * 0.15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(firmware.major)")
                    .font(.system(size: size * 0.52, weight: .bold, design: .rounded))
            }
            .foregroundStyle(style.ink)
            .padding(.horizontal, size * 0.06)
            // The gloss every icon of the time had.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 1.5, height: size * 0.8)
                .offset(y: -size * 0.36)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(Color.black.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        .overlay(alignment: .bottomTrailing) {
            if let tag = firmware.prereleaseLabel {
                Text(tag)
                    .font(.system(size: max(7, size * 0.17), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(tag == "GM" ? Color(red: 0.80, green: 0.58, blue: 0.10) : Color(red: 0.86, green: 0.22, blue: 0.16),
                                in: Capsule())
                    .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                    .offset(x: size * 0.16, y: size * 0.1)
            }
        }
        .accessibilityLabel("\(firmware.systemName)\(firmware.prereleaseLabel.map { ", \($0.lowercased())" } ?? "")")
    }

    /// Each major version's tile colours and the ink on them.
    private static func style(_ major: Int) -> (colors: [Color], ink: Color) {
        func rgb(_ v: UInt32) -> Color { Six.ui(v).swiftUI }
        switch major {
        case 1: return ([rgb(0x5A5F66), rgb(0x1E2024)], .white)
        case 2: return ([rgb(0x6EA8F2), rgb(0x1F5BBF)], .white)
        case 3: return ([rgb(0x7FD08A), rgb(0x2B8A3E)], .white)
        case 4: return ([rgb(0xE9ECF0), rgb(0x9AA1AA)], rgb(0x23272D))
        case 5: return ([rgb(0x8FD3F5), rgb(0x2A7FC4)], .white)
        case 6: return ([rgb(0xFFFFFF), rgb(0xC9CED5)], rgb(0x2E5FAF))
        case 7: return ([rgb(0xFF8A5C), rgb(0xD9367A)], .white)
        default: return ([rgb(0xB5BAC2), rgb(0x6B717A)], .white)
        }
    }
}
