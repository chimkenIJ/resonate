import Foundation

/// Distances as shown on screen ("40 m") and as spoken ("40 meters").
nonisolated enum DistanceText {
    static func short(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return "\(rounded(meters)) m"
    }

    static func spoken(_ meters: Double) -> String {
        if meters >= 1000 {
            let km = (meters / 100).rounded() / 10
            return km == 1 ? "1 kilometer" : "\(km.formatted()) kilometers"
        }
        let m = rounded(meters)
        return m == 1 ? "1 meter" : "\(m) meters"
    }

    /// Whole meters up close, steps of 5 past 20 m, steps of 10 past 100 m.
    private static func rounded(_ meters: Double) -> Int {
        switch meters {
        case ..<1: return 1
        case ..<20: return Int(meters.rounded())
        case ..<100: return Int((meters / 5).rounded()) * 5
        default: return Int((meters / 10).rounded()) * 10
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
