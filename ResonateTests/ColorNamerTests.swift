import Foundation
import Testing
@testable import Resonate

struct ColorNamerTests {
    private func name(_ hex: UInt32) -> String {
        ColorNamer.reading(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                           blue: Double(hex & 0xFF) / 255).name
    }

    @Test func namesEverydayColors() {
        #expect(name(0x000000) == "Black")
        #expect(name(0xFFFFFF) == "White")
        #expect(name(0x1A2847) == "Navy blue")
        #expect(name(0xD42020) == "Red")
        #expect(name(0x2F8A3B) == "Green")
        #expect(name(0xFFE000) == "Yellow")
        #expect(name(0x7D7D7D) == "Gray")
    }

    @Test func groupsIntoFamilies() {
        let reading = ColorNamer.reading(red: 0.05, green: 0.3, blue: 0.1)
        #expect(reading.family == "Green")
        #expect(reading.hex == "#0C4C19")
    }
}
