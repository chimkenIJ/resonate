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
        /// Walking back along the route, away from the destination.
        case wrongWay
        /// Turned around and heading the right way again.
        case rightWay
        case arrived
    }

    /// Announce a maneuver when it is this close…
    static let approachDistance = 25.0
    /// …but not when it's already this close: back-to-back maneuvers would otherwise get
    /// "In about 10 meters, turn right" immediately followed by "Turn right".
    static let minimumApproachDistance = 15.0
    /// A maneuver counts as reached this far before it along the route (a little more with poor GPS)…
    static let reachAhead = 6.0
    /// …or when the user is this close to it in a straight line.
    static let reachRadius = 10.0
    /// Within this distance of the route line (plus GPS accuracy, up to 20 m), the user is on it,
    /// and their progress along it counts. Before that (still inside, crossing a parking lot)
    /// upcoming turns aren't announced.
    static let onPathDistance = 15.0
    /// Walking back along the route this far from the furthest point reached means the wrong way…
    static let wrongWayDistance = 12.0
    /// …and it's said again this often if the user keeps going.
    static let wrongWayRepeat: TimeInterval = 30
    /// Off route beyond this distance (plus GPS accuracy, up to 30 m)…
    static let offRouteDistance = 30.0
    /// …for at least this long, so one bad GPS reading doesn't trigger a reroute.
    static let offRouteDelay: TimeInterval = 8
    static let hazardDistance = 20.0
    static let arrivalRadius = 12.0
    /// A turn reached farther away than this (poor GPS widens the radius) is announced with its distance,
    /// "In about 20 meters, turn right", so it isn't mistaken for "turn right now".
    static let turnNowDistance = 8.0

    private(set) var route: Route
    private(set) var stepIndex = 0
    private(set) var isOffRoute = false
    private(set) var hasArrived = false
    private var announcedApproach: Set<Int> = []
    private var announcedHazards: Set<Int> = []
    private var offRouteSince: Date?
    /// How far the user was from the maneuver when it counted as reached.
    private(set) var reachedDistance = 0.0

    /// Meters walked along the route line. Only moves forward, so distances count down.
    private(set) var progress = 0.0
    private(set) var isOnPath = false
    private(set) var isWrongWay = false
    private var wrongWaySaidAt: Date?
    /// Meters along the route of each polyline point, each maneuver, and each crossing.
    private let cumulative: [Double]
    private let stepAlong: [Double]
    private let crossingAlong: [Double]

    init(route: Route) {
        self.route = route
        let cumulative = Self.cumulativeLengths(route.polyline)
        self.cumulative = cumulative
        var previous = 0.0
        stepAlong = route.steps.map { step in
            let along: Double
            if let index = step.shapeIndex, cumulative.indices.contains(index) {
                along = cumulative[index]
            } else {
                // Search from the previous maneuver on, in case the route passes the same spot twice.
                along = Self.project(step.start, on: route.polyline, cumulative, from: previous, to: .infinity)?.along ?? previous
            }
            previous = along
            return along
        }
        crossingAlong = route.crossings.map { Self.project($0, on: route.polyline, cumulative, from: 0, to: .infinity)?.along ?? -1 }
    }

    /// Meters along the route to the next maneuver (or the end), once the user is on the route.
    var distanceToNextManeuver: Double? {
        guard isOnPath else { return nil }
        let next = stepIndex + 1
        let target = stepAlong.indices.contains(next) ? stepAlong[next] : (cumulative.last ?? 0)
        return max(target - progress, 0)
    }

    /// True near a street crossing the route is about to use, where a walk signal matters.
    var isNearCrossing: Bool {
        isOnPath && crossingAlong.contains { $0 >= 0 && (-5...30).contains($0 - progress) }
    }

    var currentStep: RouteStep? {
        route.steps.indices.contains(stepIndex) ? route.steps[stepIndex] : nil
    }

    mutating func update(_ fix: LocationFix) -> [Event] {
        guard !hasArrived else { return [] }
        var events: [Event] = []

        // Arrival first: being at the destination ends navigation even if steps were skipped.
        if fix.point.distance(to: route.arrivalPoint) <= Self.arrivalRadius {
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

        // Progress along the route: only near where the user already is, so a route that doubles back
        // doesn't jump ahead, and only forward.
        let onPathLimit = Self.onPathDistance + min(fix.accuracy, 20)
        if let projected = Self.project(fix.point, on: route.polyline, cumulative, from: progress - 60, to: progress + 150),
           projected.offset <= onPathLimit {
            isOnPath = true
            progress = max(progress, projected.along)
            // Going backward along the route: say "Turn around" rather than counting the distance up.
            let behind = progress - projected.along
            if behind >= Self.wrongWayDistance {
                if !isWrongWay || fix.timestamp.timeIntervalSince(wrongWaySaidAt ?? .distantPast) >= Self.wrongWayRepeat {
                    isWrongWay = true
                    wrongWaySaidAt = fix.timestamp
                    events.append(.wrongWay)
                }
                return events
            } else if isWrongWay, behind <= Self.wrongWayDistance / 2 {
                isWrongWay = false
                events.append(.rightWay)
            }
        } else {
            isOnPath = false
        }

        // Reached a maneuver (the latest one passed, in case GPS skipped past a close pair).
        let ahead = Self.reachAhead + min(fix.accuracy, 20) * 0.2
        if let reached = route.steps.indices.dropFirst(stepIndex + 1).last(where: { index in
            (isOnPath && stepAlong[index] - progress <= ahead) || fix.point.distance(to: route.steps[index].start) <= Self.reachRadius
        }) {
            stepIndex = reached
            reachedDistance = isOnPath ? max(stepAlong[reached] - progress, 0) : fix.point.distance(to: route.steps[reached].start)
            if route.steps[reached].maneuver == .arrive {
                hasArrived = true
                events.append(.arrived)
            } else {
                events.append(.reached(stepIndex: reached))
            }
            return events
        }

        // Approaching the next maneuver: only once the user is walking the path that leads to it.
        let next = stepIndex + 1
        if isOnPath, route.steps.indices.contains(next), !announcedApproach.contains(next),
           route.steps[next].maneuver != .arrive {
            let distance = stepAlong[next] - progress
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
            return Self.inDistance(distance, route.steps[index])
        case .reached(let index):
            let step = route.steps[index]
            return reachedDistance > Self.turnNowDistance ? Self.inDistance(reachedDistance, step) : step.spoken
        case .hazardAhead(let hazard):
            return hazard.spoken
        case .offRoute:
            return "You're off the route. Finding a new one."
        case .backOnRoute:
            return "You're back on the route."
        case .wrongWay:
            return "Turn around. You're walking away from the route."
        case .rightWay:
            return "That's the right way."
        case .arrived:
            guard let entrance = route.entrance else { return "You've arrived at \(route.destination.name)." }
            let door = entrance.spokenDoor.map { " \($0)" } ?? ""
            return "You've arrived at \(entrance.spokenName) of \(route.destination.name).\(door)"
        }
    }

    // MARK: Geometry

    private static func cumulativeLengths(_ polyline: [GeoPoint]) -> [Double] {
        var total = 0.0
        return polyline.indices.map { i in
            if i > 0 { total += polyline[i - 1].distance(to: polyline[i]) }
            return total
        }
    }

    /// The closest point on the route to `point`, among segments between `from` and `to` meters along it.
    static func project(_ point: GeoPoint, on polyline: [GeoPoint], _ cumulative: [Double],
                        from: Double, to: Double) -> (along: Double, offset: Double)? {
        guard polyline.count > 1 else { return polyline.first.map { (0, point.distance(to: $0)) } }
        var best: (along: Double, offset: Double)?
        for i in 0..<(polyline.count - 1) where cumulative[i + 1] >= from && cumulative[i] <= to {
            let a = polyline[i], b = polyline[i + 1]
            let offset = point.distance(toSegmentFrom: a, to: b)
            let length = cumulative[i + 1] - cumulative[i]
            // How far along the segment the closest point is: from the distances to both ends.
            let da = point.distance(to: a), db = point.distance(to: b)
            let t = length > 0 ? max(0, min(1, (da * da - db * db + length * length) / (2 * length * length))) : 0
            if best == nil || offset < best!.offset { best = (cumulative[i] + t * length, offset) }
        }
        return best
    }

    /// "In about 20 meters, turn right onto Plum Street."
    private static func inDistance(_ distance: Double, _ step: RouteStep) -> String {
        let phrase = step.alertInstruction ?? "\(step.instruction)."
        return "In about \(DistanceText.spoken(distance)), \(phrase.prefix(1).lowercased() + phrase.dropFirst())"
    }
}
