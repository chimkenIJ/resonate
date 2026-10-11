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
    /// The spoken text in reusable pieces ("Stop.", "Bike", "ahead, slightly left.").
    /// Each piece is pre-recorded in the app's voice, so alerts play instantly and offline.
    var fragments: [String]? = nil

    /// What's said out loud. With fragments, exactly those (the screen can show more than is spoken).
    var spokenText: String { fragments?.joined(separator: " ") ?? "\(headline) \(guidance)" }
}

/// Vibration patterns. Two pulses means "heads up".
nonisolated enum HapticCue: String, Codable, Hashable, Sendable {
    case tap, headsUp, stop, turnLeft, turnRight, arrived
}

/// Short sounds for users who chose "Tones".
nonisolated enum ToneCue: String, Codable, Hashable, Sendable {
    case headsUp, stop, turn, arrived, listening
}

/// Speech queue priority, least to most important (see SpeechQueue). Safety interrupts everything;
/// directions and new walking updates cut a scene description short.
nonisolated enum SpeechPriority: Int, Comparable, Sendable {
    /// Confirmations, route overviews, assistant replies.
    case info
    /// A requested scene description.
    case snapshot
    case navigation
    case safety

    static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}
