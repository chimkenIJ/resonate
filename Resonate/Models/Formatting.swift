import Foundation

/// Distances as shown on screen ("40 m") and as spoken ("40 meters").
/// Distances in feet and miles (US). Everything is measured in meters internally.
nonisolated enum DistanceText {
    static let feetPerMeter = 3.28084
    /// Under a tenth of a mile, distances are said in feet.
    private static let feetLimit = 528.0

    /// "12 ft", "0.3 mi"
    static func short(_ meters: Double) -> String {
        let feet = meters * feetPerMeter
        if feet >= feetLimit { return "\(miles(feet)) mi" }
        return "\(rounded(feet)) ft"
    }

    /// "12 feet", "1 foot", "0.3 miles", "1 mile"
    static func spoken(_ meters: Double) -> String {
        let feet = meters * feetPerMeter
        if feet >= feetLimit {
            let value = miles(feet)
            return value == "1" ? "1 mile" : "\(value) miles"
        }
        let f = rounded(feet)
        return f == 1 ? "1 foot" : "\(f) feet"
    }

    private static func miles(_ feet: Double) -> String {
        ((feet / 5280 * 10).rounded() / 10).formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Whole feet up close, steps of 5 past 10 ft, steps of 10 past 100 ft, so numbers don't flicker.
    private static func rounded(_ feet: Double) -> Int {
        switch feet {
        case ..<1: return 1
        case ..<10: return Int(feet.rounded())
        case ..<100: return Int((feet / 5).rounded()) * 5
        default: return Int((feet / 10).rounded()) * 10
        }
    }
}

nonisolated enum DurationText {
    static func minutes(_ seconds: Double) -> Int { max(1, Int((seconds / 60).rounded())) }

    /// "12 min"
    static func short(_ seconds: Double) -> String { "\(minutes(seconds)) min" }

    /// "12 minutes"
    static func spoken(_ seconds: Double) -> String {
        let m = minutes(seconds)
        return m == 1 ? "1 minute" : "\(m) minutes"
    }
}
