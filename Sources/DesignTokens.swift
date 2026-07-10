import SwiftUI
import AppKit

// Design tokens from the "Two-Pane Redesign" handoff (claude.ai/design).
// Light values from screens 3a-3h, dark from 2a-2h.
enum DS {
    static let accent = Color(hex: 0xE0402F)                       // same in both modes
    static let accentIcon = dyn(light: 0xE0402F, dark: 0xFF6B5E)   // icons / dashed strokes
    static let accentMutedText = dyn(light: 0xA05C52, dark: 0xC9A29C)

    static let windowBg = dyn(light: 0xF4F2F0, dark: 0x1E1E20)
    static let card = Color(nsColor: NSColor(name: nil) { $0.isDark
        ? NSColor(white: 1, alpha: 0.045) : NSColor.white })
    static let hairline = Color(nsColor: NSColor(name: nil) { $0.isDark
        ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.07) })
    static let previewBg = dyn(light: 0xFBFAF9, dark: 0x161617)

    static let textPrimary = dyn(light: 0x1D1D1F, dark: 0xF5F2F0)
    static let textSecondary = dyn(light: 0x3D3D3D, dark: 0xE8E6E4)
    static let textTertiary = dyn(light: 0x6E6E73, dark: 0x98989D)
    static let textQuaternary = dyn(light: 0x98989D, dark: 0x6E6E73)
    static let sectionHeader = Color(hex: 0x8E8E93)
    static let monoBody = dyn(light: 0x55524F, dark: 0xB8B6B4)
    static let mdHeading = dyn(light: 0xC73A2A, dark: 0xFF8A7A)

    static let success = dyn(light: 0x28A745, dark: 0x30D158)
    static let warning = dyn(light: 0xFF9500, dark: 0xFF9F0A)
    static let error = dyn(light: 0xFF3B30, dark: 0xFF453A)
    static let errorText = dyn(light: 0xD13024, dark: 0xFF6961)

    static let selection = Color(nsColor: NSColor(name: nil) { $0.isDark
        ? NSColor(red: 0.878, green: 0.251, blue: 0.184, alpha: 0.22)
        : NSColor(red: 0.878, green: 0.251, blue: 0.184, alpha: 0.13) })
    static let rowHover = Color(nsColor: NSColor(name: nil) { $0.isDark
        ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.04) })
    static let secondaryButtonBg = Color(nsColor: NSColor(name: nil) { $0.isDark
        ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.06) })
    static let pillBg = Color(nsColor: NSColor(name: nil) { $0.isDark
        ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05) })
    static let dropStripBg = accent.opacity(0.07)
    static let dropStripStroke = accent.opacity(0.4)

    private static func dyn(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

// Shared button styles
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(DS.accent.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DS.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(DS.secondaryButtonBg.opacity(configuration.isPressed ? 0.6 : 1)))
    }
}
