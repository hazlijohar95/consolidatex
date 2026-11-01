import SwiftUI

/// One ink stepped by opacity, hairline strokes, small type, and colour reserved for status.
enum Theme {
    static func ink(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }
    static let stroke = ink(0.07)
    static let selection = ink(0.08)
    static let hover = ink(0.05)
    static let good = Color(red: 0.06, green: 0.73, blue: 0.51)
    static let warn = Color(red: 0.91, green: 0.77, blue: 0.28)
    static let bad = Color(red: 0.96, green: 0.25, blue: 0.37)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// The account new sessions start on. Fixed rather than the system accent, so it never reads as a warning.
    static let pick = Color(nsColor: .systemBlue)
    static let radius: CGFloat = 6

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static let title = sans(13, .medium)
    static let caption = sans(11)
    static let figure = mono(11)

    /// Calm until it matters: neutral below 85%, yellow near the cap, red at it.
    static func level(_ percent: Double) -> Color {
        percent >= 100 ? bad : percent >= 85 ? warn : ink(0.55)
    }
}
