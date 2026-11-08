import AppKit
import SwiftUI

/// opencode's design language, from its v2 tokens (`packages/ui/src/styles/tokens` in opencode):
/// greys stepped by role in light and dark, hairline borders, one high-contrast button for the
/// action a moment asks for, and colour kept for state.
enum Theme {
    /// The panel: opencode's deepest background.
    static let background = color(light: 0xFAFAFA, dark: 0x161616)
    /// One layer up, for the picked row and cards.
    static let raised = color(light: 0xFFFFFF, dark: 0x242424)
    static let hover = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.06)
    static let pressed = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    static let border = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.10)
    static let borderMuted = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)

    /// Names and numbers.
    static let text = color(light: 0x161616, dark: 0xF2F2F2)
    /// What explains them.
    static let muted = color(light: 0x5C5C5C, dark: 0xAEAEAE)
    /// Labels and hints.
    static let faint = color(light: 0x808080, dark: 0x808080)

    /// The account new sessions start on.
    static let accent = color(light: 0x3B5CF6, dark: 0xA2BCFF)
    static let good = color(light: 0x198B43, dark: 0x6BD586)
    static let warn = color(light: 0xCB9F34, dark: 0xF2CF76)
    static let bad = color(light: 0xB82D35, dark: 0xF17471)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    static let contrast = color(light: 0x242424, dark: 0x5C5C5C)
    static let onContrast = color(light: 0xFFFFFF, dark: 0xFAFAFA)

    static let radius: CGFloat = 6

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static let title = sans(13, .medium)
    static let caption = sans(11)
    /// Numbers line up in columns without a monospaced face.
    static let figure = sans(11).monospacedDigit()

    /// Calm until it matters: `neutral` below 85%, yellow near the cap, red at it.
    static func level(_ percent: Double, neutral: Color = faint) -> Color {
        percent >= 100 ? bad : percent >= 85 ? warn : neutral
    }

    private static func color(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// opencode's contrast button: a neutral, high-contrast fill with a soft top light.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 5)
            configuration.label
                .font(Theme.sans(12, .medium))
                .foregroundStyle(Theme.onContrast)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    shape.fill(Theme.contrast)
                        .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0)], startPoint: .top, endPoint: .bottom)))
                        .overlay(shape.fill(.white.opacity(configuration.isPressed ? 0.24 : hovering ? 0.12 : 0)))
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// opencode's ghost button: just text until the pointer is on it.
struct GhostButtonStyle: ButtonStyle {
    var color: Color = Theme.muted

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, color: color)
    }

    private struct Styled: View {
        let configuration: Configuration
        let color: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.sans(12))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(configuration.isPressed ? Theme.pressed : hovering ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
