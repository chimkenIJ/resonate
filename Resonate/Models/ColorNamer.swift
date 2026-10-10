import Foundation

/// Names a color the way people do ("Navy blue", "Light gray", "Forest green").
/// Compares in CIELAB, where distance matches how different colors look, against everyday color names.
/// Pure logic, easy to test.
nonisolated enum ColorNamer {
    nonisolated struct Named: Sendable {
        let name: String
        let family: String
        let lab: (l: Double, a: Double, b: Double)
    }

    /// Everyday names, grouped by family. Hex values are typical examples of each.
    private static let palette: [(String, String, UInt32)] = [
        // Neutrals
        ("Black", "Black", 0x111111), ("Charcoal", "Gray", 0x36454F), ("Dark gray", "Gray", 0x505050),
        ("Gray", "Gray", 0x808080), ("Light gray", "Gray", 0xC0C0C0), ("White", "White", 0xF8F8F8),
        ("Off-white", "White", 0xF0EDE4), ("Cream", "White", 0xFFF8DC),
        // Reds and pinks
        ("Red", "Red", 0xD62828), ("Bright red", "Red", 0xFF1A1A), ("Dark red", "Red", 0x8B0000),
        ("Maroon", "Red", 0x6B1A1A), ("Burgundy", "Red", 0x800020), ("Brick red", "Red", 0x9A3B2E),
        ("Pink", "Pink", 0xF4A6B8), ("Light pink", "Pink", 0xFFD1DC), ("Hot pink", "Pink", 0xFF4F9A),
        ("Magenta", "Pink", 0xD81B9A),
        // Oranges and browns
        ("Orange", "Orange", 0xF57C00), ("Light orange", "Orange", 0xFFB347), ("Coral", "Orange", 0xFF7F50),
        ("Peach", "Orange", 0xFFCBA4), ("Rust", "Orange", 0xB7410E),
        ("Brown", "Brown", 0x8B5A2B), ("Dark brown", "Brown", 0x4E3524), ("Tan", "Brown", 0xD2B48C),
        ("Beige", "Brown", 0xE8DCC2), ("Khaki", "Brown", 0xC3B091), ("Camel", "Brown", 0xC19A6B),
        // Yellows
        ("Yellow", "Yellow", 0xFFDD00), ("Light yellow", "Yellow", 0xFFF59D), ("Gold", "Yellow", 0xD4AF37),
        ("Mustard", "Yellow", 0xD1A000),
        // Greens
        ("Green", "Green", 0x2E8B3A), ("Dark green", "Green", 0x0B4F1C), ("Forest green", "Green", 0x228B22),
        ("Lime green", "Green", 0x7CCD32), ("Light green", "Green", 0x9EE29E), ("Mint green", "Green", 0xB8F0C8),
        ("Olive", "Green", 0x7A7A1F), ("Sage green", "Green", 0x9CAF88), ("Teal", "Green", 0x00807A),
        // Blues
        ("Blue", "Blue", 0x1F5FD6), ("Dark blue", "Blue", 0x0A1F7A), ("Navy blue", "Blue", 0x1B2A4A),
        ("Royal blue", "Blue", 0x3A5FE0), ("Light blue", "Blue", 0xA7CFEA), ("Sky blue", "Blue", 0x7EC8EE),
        ("Denim blue", "Blue", 0x3C5A8C), ("Turquoise", "Blue", 0x3FD0C9),
        // Purples
        ("Purple", "Purple", 0x7B2D9B), ("Dark purple", "Purple", 0x3E1A57), ("Lavender", "Purple", 0xC8B6E8),
        ("Violet", "Purple", 0x8A3FE0), ("Plum", "Purple", 0x8E4585),
    ]

    private static let named: [Named] = palette.map { name, family, hex in
        Named(name: name, family: family, lab: lab(red: Double((hex >> 16) & 0xFF) / 255,
                                                   green: Double((hex >> 8) & 0xFF) / 255,
                                                   blue: Double(hex & 0xFF) / 255))
    }

    /// The closest everyday name for an sRGB color (components 0...1).
    static func reading(red: Double, green: Double, blue: Double) -> ColorReading {
        let target = lab(red: red, green: green, blue: blue)
        let best = named.min { distance($0.lab, target) < distance($1.lab, target) }!
        let hex = String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        return ColorReading(name: best.name, family: best.family, hex: hex)
    }

    private static func distance(_ a: (l: Double, a: Double, b: Double), _ b: (l: Double, a: Double, b: Double)) -> Double {
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return dl * dl + da * da + db * db
    }

    /// sRGB (0...1) → CIELAB (D65).
    static func lab(red: Double, green: Double, blue: Double) -> (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(red), g = linear(green), b = linear(blue)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
