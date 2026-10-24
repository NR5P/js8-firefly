import SwiftUI
import JS8Core

enum Theme {
    static let bg = Color(red: 0.035, green: 0.045, blue: 0.075)
    static let bg2 = Color(red: 0.06, green: 0.075, blue: 0.12)
    static let card = Color(red: 0.08, green: 0.10, blue: 0.16)
    static let cardHi = Color(red: 0.11, green: 0.14, blue: 0.22)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.20, green: 0.88, blue: 1.0)
    static let accent2 = Color(red: 0.45, green: 0.55, blue: 1.0)
    static let rx = Color(red: 0.35, green: 0.95, blue: 0.55)
    static let tx = Color(red: 1.0, green: 0.36, blue: 0.30)
    static let warn = Color(red: 1.0, green: 0.75, blue: 0.25)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.30)

    static let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.03, green: 0.04, blue: 0.08), Color(red: 0.05, green: 0.07, blue: 0.13)],
        startPoint: .top, endPoint: .bottom)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func snrColor(_ snr: Int) -> Color {
        switch snr {
        case ..<(-20): return Color(red: 1.0, green: 0.45, blue: 0.35)
        case -20..<(-10): return warn
        default: return rx
        }
    }

    static func modeColor(_ m: JS8Submode) -> Color {
        switch m {
        case .slow: return Color(red: 0.6, green: 0.5, blue: 1.0)
        case .normal: return accent
        case .fast: return rx
        case .turbo: return warn
        case .ultra: return tx
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.card.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            )
    }
}

struct Chip: View {
    let text: String
    var color: Color = Theme.accent
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.mono(11, .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(filled ? Theme.bg : color)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
            .overlay(Capsule().stroke(color.opacity(filled ? 0 : 0.35), lineWidth: 1))
    }
}

struct SectionHeader: View {
    let title: String
    var icon: String?
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).foregroundStyle(Theme.accent) }
            Text(title.uppercased())
                .font(Theme.rounded(12, .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.dim)
            Spacer()
            trailing
        }
    }
}

extension View {
    func glow(_ color: Color, radius: CGFloat = 8) -> some View {
        shadow(color: color.opacity(0.55), radius: radius)
    }
}
