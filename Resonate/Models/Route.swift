import Foundation

/// Accessibility options sent to the routing backend (Valhalla pedestrian costing).
nonisolated struct RoutingPreferences: Codable, Hashable, Sendable {
    var avoidSteps = true
    /// Maximum grade as a fraction (0.08 = 8%).
    var maxIncline: Double = 0.08
    var preferTactilePaving = true
    var preferAudioSignals = true
}

/// A walking turn in the route.
nonisolated enum Maneuver: String, Codable, Hashable, Sendable {
    case depart, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight
    case uTurn, crossing, audioCrossing, elevator, steps, ramp, arrive

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
        case .steps: "figure.stairs"
        case .ramp: "arrow.up.forward"
        case .arrive: "flag.checkered"
        }
    }

    var accent: Accent {
        switch self {
        case .audioCrossing, .crossing: .mauve
        case .elevator: .sage
        case .steps: .clay
        case .arrive: .sand
        default: .slate
        }
    }
}

nonisolated struct RouteStep: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    /// Short text for the screen: "Turn right onto Plum Street".
    var instruction: String
    /// Distance from this maneuver to the next one.
    var distanceMeters: Double
    var maneuver: Maneuver
    /// Point where this maneuver happens, used to trigger the spoken instruction.
    var start: GeoPoint
    /// Fuller sentence to speak at the maneuver, including crossing and curb notes.
    var spokenInstruction: String? = nil
    /// Short form to speak a little before the maneuver: "Turn right onto Plum Street."
    var alertInstruction: String? = nil

    var spoken: String { spokenInstruction ?? "\(instruction)." }
}

/// Accessibility features along a route, shown as chips under the summary.
nonisolated enum RouteFeature: Codable, Hashable, Sendable {
    case curbRamps
    case audioCrossings
    case tactilePaving
    case elevators(Int)
    case steps(Int)
    case raisedCurbs(Int)
    /// Some crossings have no kerb tag in OSM, so we can't promise a curb ramp there.
    case unverifiedSegments

    var label: String {
        switch self {
        case .curbRamps: "Curb ramps"
        case .audioCrossings: "Audio crossings"
        case .tactilePaving: "Tactile paving"
        case .elevators(let n): n == 1 ? "1 elevator" : "\(n) elevators"
        case .steps(let n): n == 1 ? "1 set of steps" : "\(n) sets of steps"
        case .raisedCurbs(let n): n == 1 ? "1 raised curb" : "\(n) raised curbs"
        case .unverifiedSegments: "Some curbs unverified"
        }
    }

    var accent: Accent {
        switch self {
        case .curbRamps: .sand
        case .audioCrossings: .mauve
        case .tactilePaving: .slate
        case .elevators: .sage
        case .steps, .raisedCurbs: .clay
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

/// Something to warn about while walking the route.
nonisolated struct RouteHazard: Hashable, Codable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case raisedCurb = "raised_curb"
        case steps
    }

    var kind: Kind
    var coordinate: GeoPoint

    var spoken: String {
        switch kind {
        case .raisedCurb: "Raised curb ahead. Check the edge with your cane."
        case .steps: "Steps ahead."
        }
    }
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
    var hazards: [RouteHazard] = []

    /// Meters from `point` to the nearest part of the route line.
    func distanceFromPath(_ point: GeoPoint) -> Double {
        guard polyline.count > 1 else {
            return polyline.first.map(point.distance(to:)) ?? .infinity
        }
        return zip(polyline, polyline.dropFirst())
            .map { point.distance(toSegmentFrom: $0, to: $1) }
            .min() ?? .infinity
    }

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

/// The steepest slope a route may use, in plain words.
nonisolated enum HillLimit: Double, CaseIterable, Identifiable, Sendable {
    case gentle = 0.04
    case moderate = 0.08
    case steep = 0.15

    var id: Double { rawValue }
    var incline: Double { rawValue }

    /// The nearest option for a stored incline.
    init(incline: Double) {
        self = Self.allCases.min { abs($0.rawValue - incline) < abs($1.rawValue - incline) } ?? .moderate
    }

    var title: String {
        switch self {
        case .gentle: "Gentle"
        case .moderate: "Moderate"
        case .steep: "Steep"
        }
    }

    var explanation: String {
        switch self {
        case .gentle: "Barely feels like a slope (up to 4%). Easiest on wheelchairs and tired legs; routes may be longer."
        case .moderate: "About as steep as a wheelchair ramp (up to 8%). A good balance for most people."
        case .steep: "Steep hills are fine (up to 15%). Shortest routes, but harder work."
        }
    }

    var accent: Accent {
        switch self {
        case .gentle: .sage
        case .moderate: .sand
        case .steep: .clay
        }
    }
}
