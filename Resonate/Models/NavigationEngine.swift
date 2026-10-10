import Foundation

/// Turn-by-turn state machine. Feed it GPS fixes; it says what to announce.
/// Pure logic, no I/O, so it is easy to test and runs fully on-device.
nonisolated struct NavigationEngine: Sendable {
    nonisolated enum Event: Equatable, Sendable {
        /// The next maneuver is close: "In about 20 meters, turn right."
        case approaching(stepIndex: Int, distance: Double)
        /// The user is at a maneuver point.
        case reached(stepIndex: Int)
        case hazardAhead(RouteHazard)
        /// Too far from the route for long enough to need a new one.
        case offRoute
        case backOnRoute
        case arrived
    }

    /// Announce a maneuver when it is this close…
    static let approachDistance = 25.0
    /// …but not when it's already this close: back-to-back maneuvers would otherwise get
    /// "In about 10 meters, turn right" immediately followed by "Turn right".
    static let minimumApproachDistance = 15.0
    /// Count a maneuver as reached within this radius (grows with poor GPS accuracy, up to 20 m).
    static let reachRadius = 10.0
    /// Off route beyond this distance (plus GPS accuracy, up to 30 m)…
    static let offRouteDistance = 30.0
    /// …for at least this long, so one bad GPS reading doesn't trigger a reroute.
    static let offRouteDelay: TimeInterval = 8
    static let hazardDistance = 20.0
    static let arrivalRadius = 12.0

    private(set) var route: Route
    private(set) var stepIndex = 0
    private(set) var isOffRoute = false
    private(set) var hasArrived = false
    private var announcedApproach: Set<Int> = []
    private var announcedHazards: Set<Int> = []
    private var offRouteSince: Date?

    init(route: Route) {
        self.route = route
    }

    var currentStep: RouteStep? {
        route.steps.indices.contains(stepIndex) ? route.steps[stepIndex] : nil
    }

    mutating func update(_ fix: LocationFix) -> [Event] {
        guard !hasArrived else { return [] }
        var events: [Event] = []

        // Arrival first: being at the destination ends navigation even if steps were skipped.
        if fix.point.distance(to: route.destination.coordinate) <= Self.arrivalRadius {
            hasArrived = true
            stepIndex = max(route.steps.count - 1, 0)
            return [.arrived]
        }

        // Off-route detection.
        let deviation = route.distanceFromPath(fix.point)
        if deviation > Self.offRouteDistance + min(fix.accuracy, 30) {
            let since = offRouteSince ?? fix.timestamp
            offRouteSince = since
            if !isOffRoute, fix.timestamp.timeIntervalSince(since) >= Self.offRouteDelay {
                isOffRoute = true
                events.append(.offRoute)
            }
            return events
        }
        offRouteSince = nil
        if isOffRoute {
            isOffRoute = false
            events.append(.backOnRoute)
        }

        // Reached a maneuver (any later one, in case GPS skipped past a close pair).
        let radius = max(Self.reachRadius, min(fix.accuracy, 20))
        if let reached = route.steps.indices.dropFirst(stepIndex + 1).first(where: {
            fix.point.distance(to: route.steps[$0].start) <= radius
        }) {
            stepIndex = reached
            if route.steps[reached].maneuver == .arrive {
                hasArrived = true
                events.append(.arrived)
            } else {
                events.append(.reached(stepIndex: reached))
            }
            return events
        }

        // Approaching the next maneuver.
        let next = stepIndex + 1
        if route.steps.indices.contains(next), !announcedApproach.contains(next),
           route.steps[next].maneuver != .arrive {
            let distance = fix.point.distance(to: route.steps[next].start)
            if distance <= Self.approachDistance, distance >= Self.minimumApproachDistance {
                announcedApproach.insert(next)
                events.append(.approaching(stepIndex: next, distance: distance))
            }
        }

        // Hazards along the route (raised curbs, steps).
        for (index, hazard) in route.hazards.enumerated() where !announcedHazards.contains(index) {
            if fix.point.distance(to: hazard.coordinate) <= Self.hazardDistance {
                announcedHazards.insert(index)
                events.append(.hazardAhead(hazard))
            }
        }

        return events
    }

    /// Spoken text for an event.
    func announcement(for event: Event) -> String {
        switch event {
        case .approaching(let index, let distance):
            let step = route.steps[index]
            let phrase = step.alertInstruction ?? "\(step.instruction)."
            return "In about \(DistanceText.spoken(distance)), \(phrase.prefix(1).lowercased() + phrase.dropFirst())"
        case .reached(let index):
            return route.steps[index].spoken
        case .hazardAhead(let hazard):
            return hazard.spoken
        case .offRoute:
            return "You're off the route. Finding a new one."
        case .backOnRoute:
            return "You're back on the route."
        case .arrived:
            return "You've arrived at \(route.destination.name)."
        }
    }
}
