import Foundation

/// Accessibility options sent to the routing backend (Valhalla pedestrian costing).
nonisolated struct RoutingPreferences: Codable, Hashable, Sendable {
    var avoidSteps = true
    /// Maximum grade as a fraction (0.08 = 8%).
    var maxIncline = 0.08
    var preferTactilePaving = true
    var preferAudioSignals = true
}

/// A walking turn in the route.
nonisolated enum Maneuver: String, Codable, Hashable, Sendable {
    case depart, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight
    case uTurn, crossing, audioCrossing, elevator, ramp, arrive

    var systemImage: String {
        switch self {
        case .depart: "location"
        case .straight: "arrow.up"
        case .slightLeft: "arrow.up.left"
        case .left, .sharpLeft: "arrow.turn.up.left"
        case .slightRight: "arrow.up.right"
        case .right, .sharpRight: "arrow.turn.up.right"
        case .uTurn: "arrow.uturn.down"
        case .crossing: "figure.walk"
        case .audioCrossing: "speaker.wave.2"
        case .elevator: "arrow.up.arrow.down"
        case .ramp: "arrow.up.forward"
        case .arrive: "flag.checkered"
        }
    }

    var accent: Accent {
        switch self {
        case .audioCrossing, .crossing: .mauve
        case .elevator: .sage
        case .arrive: .sand
        default: .slate
        }
    }
}

nonisolated struct RouteStep: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var instruction: String
    var distanceMeters: Double
    var maneuver: Maneuver
    /// Point where this step starts, used to trigger the spoken instruction.
    var start: GeoPoint
}

/// Accessibility features along a route, shown as chips under the summary.
nonisolated enum RouteFeature: Codable, Hashable, Sendable {
    case curbRamps
    case audioCrossings
    case tactilePaving
    case elevators(Int)
    case steps(Int)
    /// Some segments have no sidewalk or kerb tags in OSM, so we can't promise they're step-free.
    case unverifiedSegments

    var label: String {
        switch self {
        case .curbRamps: "Curb ramps"
        case .audioCrossings: "Audio crossings"
        case .tactilePaving: "Tactile paving"
        case .elevators(let n): n == 1 ? "1 elevator" : "\(n) elevators"
        case .steps(let n): n == 1 ? "1 set of steps" : "\(n) sets of steps"
        case .unverifiedSegments: "Some parts unverified"
        }
    }

    var accent: Accent {
        switch self {
        case .curbRamps: .sand
        case .audioCrossings: .mauve
        case .tactilePaving: .slate
        case .elevators: .sage
        case .steps: .clay
        case .unverifiedSegments: .rose
        }
    }
}

/// Something the route deliberately avoided, drawn on the map ("Stairs avoided").
nonisolated struct AvoidedHazard: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var label: String
    var coordinate: GeoPoint
}

nonisolated struct Route: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var destination: Place
    var durationSeconds: Double
    var distanceMeters: Double
    var isStepFree: Bool
    var features: [RouteFeature]
    var steps: [RouteStep]
    var polyline: [GeoPoint]
    var avoided: [AvoidedHazard]

    /// "12 min · step-free"
    var summary: String {
        let access = isStepFree ? "step-free" : "has steps"
        return "\(DurationText.short(durationSeconds)) · \(access)"
    }

    /// "12 minutes, step-free"
    var spokenSummary: String {
        let access = isStepFree ? "step-free" : "includes steps"
        return "\(DurationText.spoken(durationSeconds)), \(access)"
    }
}
