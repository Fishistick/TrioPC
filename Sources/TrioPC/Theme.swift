import SwiftUI

enum DeskTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let accent = Color(red: 0.27, green: 0.39, blue: 0.82)
    static let accentWash = accent.opacity(0.09)
    static let rule = Color(nsColor: .separatorColor).opacity(0.45)
    static let warning = Color(nsColor: .systemOrange)
    static let warningWash = warning.opacity(0.09)
    static let title = Font.system(size: 26, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let number = Font.system(size: 66, weight: .regular, design: .rounded).monospacedDigit()
    static let trend = Font.system(size: 27, weight: .medium)
    static let identity = Font.system(size: 18, weight: .semibold)
    static let code = Font.system(size: 11, design: .monospaced)
    static let corner: CGFloat = 14
    static let gap: CGFloat = 24
}
