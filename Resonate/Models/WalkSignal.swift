import Foundation

/// What a pedestrian signal in view shows. US signals: a white walking person means walk, an
/// orange hand means don't walk.
nonisolated enum SignalReading: Hashable, Sendable {
    case walk
    case dontWalk
    /// A signal is in view but no clear walk or hand is lit (unlit, flashing off, glare, a green car light).
    case unreadable

    var spoken: String {
        switch self {
        case .walk: "Walk sign is on. Check for cars before you cross."
        case .dontWalk: "Don't walk. Wait for the walk sign."
        case .unreadable: ""
        }
    }

    var display: String {
        switch self {
        case .walk: "Walk sign is on"
        case .dontWalk: "Don't walk"
        case .unreadable: ""
        }
    }

    var systemImage: String {
        switch self {
        case .walk: "figure.walk"
        case .dontWalk, .unreadable: "hand.raised.fill"
        }
    }

    var accent: Accent { self == .walk ? .sage : .rose }
}

/// Reads a signal's lit symbol from the colors inside its box. Pure logic, easy to test.
nonisolated enum SignalClassifier {
    /// - Parameter pixels: sRGB samples from inside the signal's box, components 0...1.
    static func classify(_ pixels: [(r: Double, g: Double, b: Double)]) -> SignalReading {
        guard pixels.count >= 50 else { return .unreadable }
        var white = 0, orange = 0, green = 0, dark = 0
        for p in pixels {
            let high = max(p.r, p.g, p.b), low = min(p.r, p.g, p.b)
            if high < 0.3 { dark += 1; continue }
            guard high >= 0.7 else { continue }
            let saturation = (high - low) / high
            if saturation < 0.3 {
                white += 1
            } else if saturation >= 0.45 {
                let hue = hueDegrees(p, high: high, low: low)
                if hue <= 45 || hue >= 340 { orange += 1 } else if (90...200).contains(hue) { green += 1 }
            }
        }
        let n = Double(pixels.count)
        // A signal is a dark housing with a small lit symbol; a box that's mostly bright is sky or glare.
        guard Double(dark) / n >= 0.2, Double(white + orange + green) / n <= 0.5 else { return .unreadable }
        let minimum = max(3, Int(n * 0.02))
        if white >= minimum, white >= 2 * orange, white >= green { return .walk }
        if orange >= minimum, orange >= 2 * white, orange >= green { return .dontWalk }
        return .unreadable
    }

    private static func hueDegrees(_ p: (r: Double, g: Double, b: Double), high: Double, low: Double) -> Double {
        let delta = high - low
        guard delta > 0 else { return 0 }
        var hue: Double
        if high == p.r { hue = (p.g - p.b) / delta } else if high == p.g { hue = 2 + (p.b - p.r) / delta } else { hue = 4 + (p.r - p.g) / delta }
        hue *= 60
        return hue < 0 ? hue + 360 : hue
    }
}

/// Smooths signal readings over time and reports when the signal changes. A flashing hand still
/// reads as "don't walk". Pure logic, easy to test.
nonisolated struct WalkSignalTracker {
    /// Seconds of readings considered.
    static let window: TimeInterval = 2
    static let minimumReadings = 4
    static let agreement = 0.75
    /// The signal is forgotten after this long out of view.
    static let forgetAfter: TimeInterval = 4

    private var readings: [(time: Date, reading: SignalReading)] = []
    private var lastSeen: Date = .distantPast
    private(set) var state: SignalReading?

    /// - Parameter reading: nil when no signal is in view.
    /// - Returns: the new state when it changed to walk or don't walk (time to say it).
    mutating func update(_ reading: SignalReading?, now: Date) -> SignalReading? {
        if let reading {
            lastSeen = now
            if reading != .unreadable { readings.append((now, reading)) }
        }
        readings.removeAll { now.timeIntervalSince($0.time) > Self.window }
        if now.timeIntervalSince(lastSeen) > Self.forgetAfter {
            state = nil
            readings.removeAll()
            return nil
        }
        guard readings.count >= Self.minimumReadings else { return nil }
        let walk = readings.filter { $0.reading == .walk }.count
        let share = Double(walk) / Double(readings.count)
        let candidate: SignalReading? = share >= Self.agreement ? .walk : (1 - share >= Self.agreement ? .dontWalk : nil)
        guard let candidate, candidate != state else { return nil }
        state = candidate
        return candidate
    }
}
