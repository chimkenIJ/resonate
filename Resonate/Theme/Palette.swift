import SwiftUI

extension Color {
    /// Creates an opaque color from a 0xRRGGBB literal.
    nonisolated init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Color {
    /// Parses "#RRGGBB". Returns nil for anything else.
    nonisolated init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// Neutral design tokens from DESIGN_SPEC.md. The app is dark mode only.
enum Palette {
    static let background = Color(hex: 0x121314)
    static let surface = Color(hex: 0x1C1D1F)
    static let surfaceRaised = Color(hex: 0x2A2C30)
    static let border = Color(hex: 0x333538)
    static let rowBorder = Color(hex: 0x2E3033)
    static let divider = Color(hex: 0x3A3D42)
    static let sheetHandle = Color(hex: 0x45484D)
    static let unselectedRing = Color(hex: 0x6A6D72)

    static let textPrimary = Color(hex: 0xF2F0EB)
    static let textSecondary = Color(hex: 0xCFCCC5)
    static let textMuted = Color(hex: 0xB4B1AA)
    /// Text and icons on any accent color or on the off-white primary fill. Never use white there.
    static let onAccent = Color(hex: 0x121314)
    /// Subtitle text on the off-white search card.
    static let onLightSecondary = Color(hex: 0x3D3A35)

    static let gridLine = Color(hex: 0x1B1C1F)
    static let mapBackground = Color(hex: 0x16171A)
    static let mapGridLine = Color(hex: 0x1D1F22)
    static let paperLight = Color(hex: 0xE9E5DC)
    static let paperDark = Color(hex: 0xCFCAC0)
}

/// Accent colors. They differ in brightness as well as hue so color-blind users can tell them apart.
nonisolated enum Accent: String, CaseIterable, Codable, Hashable, Sendable {
    case sand, sage, slate, clay, mauve, rose

    var color: Color {
        switch self {
        case .sand: Color(hex: 0xD9B26A)
        case .sage: Color(hex: 0x8FAE8B)
        case .slate: Color(hex: 0x7E9CC4)
        case .clay: Color(hex: 0xC9785D)
        case .mauve: Color(hex: 0xA99AC9)
        case .rose: Color(hex: 0xC98F96)
        }
    }

    /// Darker shade used for the folder tab behind a folder card.
    var tabColor: Color {
        switch self {
        case .sand: Color(hex: 0xB8975A)
        case .sage: Color(hex: 0x76957A)
        case .slate: Color(hex: 0x6886AE)
        case .clay: Color(hex: 0xAF6249)
        case .mauve: Color(hex: 0x9182B2)
        case .rose: Color(hex: 0xB07880)
        }
    }

    /// Spoken name, used when the user picks a folder color with VoiceOver.
    var spokenName: String {
        switch self {
        case .sand: "Sand yellow"
        case .sage: "Sage green"
        case .slate: "Slate blue"
        case .clay: "Clay orange"
        case .mauve: "Mauve purple"
        case .rose: "Rose pink"
        }
    }
}
