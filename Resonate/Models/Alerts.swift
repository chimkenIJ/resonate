import Foundation

nonisolated enum AlertSeverity: Int, Codable, Comparable, Hashable, Sendable {
    case info, headsUp, stop

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .info: "Info"
        case .headsUp: "Heads up"
        case .stop: "Stop"
        }
    }

    var accent: Accent {
        switch self {
        case .info: .slate
        case .headsUp: .clay
        case .stop: .rose
        }
    }

    var hapticCue: HapticCue? {
        switch self {
        case .info: nil
        case .headsUp: .headsUp
        case .stop: .stop
        }
    }
}

/// A spoken safety alert built entirely on-device.
nonisolated struct ObstacleAlert: Hashable, Sendable {
    var severity: AlertSeverity
    /// One sentence, for example "Bike parked ahead, slightly left."
    var headline: String
    /// What to do about it, for example "Step right to pass."
    var guidance: String
    var guidanceIcon: Maneuver
    /// Keeps the same obstacle from being announced over and over.
    var dedupeKey: String
    /// The spoken text in reusable pieces ("Bike", "ahead, slightly left,", "2 meters.", "Step right to pass.").
    /// Each piece is pre-recorded in the app's voice, so alerts play instantly and offline.
    var fragments: [String]? = nil

    var spokenText: String { "\(headline) \(guidance)" }
}

/// Picks the single most important obstacle in a frame and words it as an alert.
/// Pure logic so it is easy to unit test and never touches the network.
nonisolated enum ObstacleAlertComposer {
    /// Objects farther than this are ignored.
    static let alertRange = 6.0
    static let stopRange = 1.5

    static func compose(from objects: [DetectedObject]) -> ObstacleAlert? {
        let candidates = objects.filter { object in
            guard let d = object.distanceMeters, d <= alertRange else { return false }
            return object.category != .wall && object.category != .door
        }
        guard let nearest = candidates.min(by: { priority($0) < priority($1) }),
              let distance = nearest.distanceMeters else { return nil }

        let isEdge = nearest.category == .dropOff || nearest.category == .stairs
        let severity: AlertSeverity = distance <= stopRange || (isEdge && distance <= 2) ? .stop : .headsUp
        let direction = nearest.direction
        let distanceText = DistanceText.spoken(distance)
        let headline = "\(nearest.label) \(direction.spoken), \(distanceText)."

        let guidance: String
        let icon: Maneuver
        switch (nearest.category, direction) {
        case (.dropOff, _):
            guidance = severity == .stop ? "Stop. Check the edge with your cane." : "Slow down. Edge ahead."
            icon = .straight
        case (.stairs, _):
            guidance = severity == .stop ? "Stop. Step up right in front of you." : "Slow down. Step up ahead."
            icon = .straight
        case (_, .left), (_, .slightlyLeft):
            guidance = "Step right to pass."
            icon = .slightRight
        case (_, .right), (_, .slightlyRight):
            guidance = "Step left to pass."
            icon = .slightLeft
        case (_, .ahead):
            guidance = severity == .stop ? "Stop. It's right in front of you." : "Blocked ahead. Step left or right."
            icon = .straight
        }

        return ObstacleAlert(
            severity: severity,
            headline: headline,
            guidance: guidance,
            guidanceIcon: icon,
            dedupeKey: "\(nearest.label)-\(direction.rawValue)",
            fragments: [nearest.label, "\(direction.spoken),", "\(distanceText).", guidance]
        )
    }

    /// Lower is more urgent: drop-offs first, then anything in the walking path, then by distance.
    private static func priority(_ object: DetectedObject) -> Double {
        let distance = object.distanceMeters ?? .infinity
        let inPath = [.ahead, .slightlyLeft, .slightlyRight].contains(object.direction)
        let hazardBoost = object.category == .dropOff || object.category == .stairs ? -3.0 : 0
        return distance + (inPath ? 0 : 2) + hazardBoost
    }
}

/// Vibration patterns. Two pulses means "heads up".
nonisolated enum HapticCue: String, Codable, Hashable, Sendable {
    case tap, headsUp, stop, turnLeft, turnRight, arrived
}

/// Short sounds for users who chose "Tones".
nonisolated enum ToneCue: String, Codable, Hashable, Sendable {
    case headsUp, stop, turn, arrived, listening
}

/// Speech queue priority. Safety interrupts everything else.
nonisolated enum SpeechPriority: Int, Comparable, Sendable {
    case info, navigation, safety, snapshot

    static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}
