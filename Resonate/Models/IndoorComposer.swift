import CoreGraphics
import Foundation

/// Something in a scanned room, as a footprint on the floor (world X/Z, meters).
nonisolated struct RoomElement: Sendable, Equatable {
    nonisolated enum Kind: Sendable, Equatable {
        case wall
        case door(isOpen: Bool)
        case opening
        case object
    }

    var kind: Kind
    var label: String
    var category: ObjectCategory
    /// Floor footprint in world X/Z: two points for walls and doors (a line), four for objects.
    var footprint: [SIMD2<Double>]
    /// World Y of the bottom, and the height, in meters (for drawing camera overlay boxes).
    var bottom: Double = 0
    var height: Double = 1
}

/// Where the user stands and faces, on the floor plane.
nonisolated struct FloorPose: Sendable {
    var position: SIMD2<Double>
    /// Unit vector the phone faces, flattened onto the floor.
    var forward: SIMD2<Double>

    var right: SIMD2<Double> { SIMD2(-forward.y, forward.x) }

    /// World X/Z → (forward, lateral) meters relative to the user.
    func relative(_ point: SIMD2<Double>) -> SIMD2<Double> {
        let d = point - position
        return SIMD2((d * forward).sum(), (d * right).sum())
    }
}

/// Turns a scanned room into the indoor sheet: one sentence about the nearest thing, a guidance line,
/// a mini map, and a safety alert when something is very close. Pure logic, easy to test.
nonisolated enum IndoorComposer {
    nonisolated struct Placed: Sendable {
        var element: RoomElement
        /// Footprint relative to the user: x = meters ahead, y = meters to the right.
        var points: [SIMD2<Double>]
        var distance: Double
        /// Nearest point, relative.
        var nearest: SIMD2<Double>
        /// Degrees: 0 = straight ahead, positive = right.
        var bearing: Double { atan2(nearest.y, nearest.x) * 180 / .pi }
    }

    nonisolated struct Result: Sendable {
        var headline: String
        var guidance: String
        var guidanceIcon: Maneuver
        var miniMap: [MiniMapItem]
        var alert: ObstacleAlert?
        /// Stable key for the headline, so the app doesn't re-announce "3 steps", "2 steps"…
        var announcementKey: String
    }

    static let stepLength = 0.7
    static let corridorHalfWidth = 0.45
    /// The mini map shows this many meters across.
    static let mapSpan = 6.0

    static func compose(_ elements: [RoomElement], pose: FloorPose) -> Result {
        let placed = elements.map { place($0, pose: pose) }
        let inFront = placed.filter { abs($0.bearing) <= 100 }

        // Headline: the nearest thing that isn't a wall, door, or doorway.
        let things = inFront.filter { $0.element.kind == .object }.sorted { $0.distance < $1.distance }
        let walls = inFront.filter { $0.element.kind == .wall }.sorted { $0.distance < $1.distance }
        let headline: String
        let key: String
        if let nearest = things.first, nearest.distance <= 4 {
            headline = "\(nearest.element.label) \(steps(nearest.distance)) \(phrase(for: nearest.bearing))."
            key = "\(nearest.element.label)-\(side(nearest.bearing))"
        } else if let wall = walls.first(where: { abs($0.bearing) <= 30 }), wall.distance <= 2 {
            headline = "Wall \(steps(wall.distance)) ahead."
            key = "wall-ahead"
        } else {
            headline = "The way ahead is clear."
            key = "clear"
        }

        // Guidance: how to move, which side the wall is on, where the door is.
        var parts: [String] = []
        var icon = Maneuver.straight
        let blocking = placed.filter { inCorridor($0, within: 2.5) }.sorted { $0.distance < $1.distance }
        if let block = blocking.first, block.distance <= 0.8 {
            parts.append("Stop.")
        } else if let block = blocking.first {
            if block.element.kind == .wall {
                parts.append("Wall ahead. Turn left or right.")
            } else {
                // Pass on the side with more room.
                let goRight = block.nearest.y <= 0
                parts.append(goRight ? "Step right to pass." : "Step left to pass.")
                icon = goRight ? .slightRight : .slightLeft
            }
        } else {
            parts.append("Walk straight.")
        }
        if let side = wallAlongside(placed) {
            parts.append("Wall stays on your \(side).")
        }
        if let door = placed.filter({ isDoorway($0) && $0.nearest.x > 0 && $0.distance <= 10 })
            .min(by: { $0.distance < $1.distance }) {
            parts.append(doorSentence(door))
        }

        return Result(
            headline: headline,
            guidance: parts.joined(separator: " "),
            guidanceIcon: icon,
            miniMap: placed.compactMap(mapItem),
            alert: alert(for: placed),
            announcementKey: key
        )
    }

    // MARK: Geometry

    static func place(_ element: RoomElement, pose: FloorPose) -> Placed {
        let points = element.footprint.map(pose.relative)
        let nearest = nearestPoint(to: .zero, on: points)
        let inside = points.count >= 3 && contains(points, .zero)
        return Placed(element: element, points: points, distance: inside ? 0 : simd_length(nearest), nearest: nearest)
    }

    private static func inCorridor(_ item: Placed, within range: Double) -> Bool {
        guard !isDoorway(item) else { return false }
        // Any part of the footprint inside the walking corridor ahead.
        let samples = densify(item.points)
        return samples.contains { $0.x > -0.1 && $0.x <= range && abs($0.y) <= corridorHalfWidth }
    }

    private static func isDoorway(_ item: Placed) -> Bool {
        if case .door(let open) = item.element.kind { return open }
        return item.element.kind == .opening
    }

    /// A wall roughly parallel to the walking direction, close beside the user.
    private static func wallAlongside(_ placed: [Placed]) -> String? {
        let candidates = placed.filter { item in
            guard item.element.kind == .wall, item.points.count == 2, item.distance <= 1.6,
                  abs(item.nearest.y) >= 0.2 else { return false }
            let direction = item.points[1] - item.points[0]
            let angle = abs(atan2(direction.y, direction.x) * 180 / .pi)
            return angle < 30 || angle > 150
        }
        guard let wall = candidates.min(by: { $0.distance < $1.distance }) else { return nil }
        return wall.nearest.y < 0 ? "left" : "right"
    }

    private static func doorSentence(_ door: Placed) -> String {
        let name = door.element.kind == .opening ? "Doorway" : "Door"
        let open = door.element.kind == .opening ? "" : " is open"
        switch abs(door.bearing) {
        case ...20: return "\(name)\(open) ahead."
        case ...60: return "\(name)\(open) ahead, a little to the \(door.bearing < 0 ? "left" : "right")."
        default: return "\(name)\(open) on your \(door.bearing < 0 ? "left" : "right")."
        }
    }

    private static func alert(for placed: [Placed]) -> ObstacleAlert? {
        guard let closest = placed.filter({ inCorridor($0, within: 1.5) }).min(by: { $0.distance < $1.distance }) else {
            return nil
        }
        let severity: AlertSeverity = closest.distance <= 0.8 ? .stop : .headsUp
        let isStairs = closest.element.category == .stairs
        let place = closest.distance <= 0.8 ? "right in front of you." : "\(steps(closest.distance)) ahead."
        let headline = "\(closest.element.label) \(place)"
        let guidance: String
        if isStairs {
            guidance = "Stairs. Find the railing and check each step with your cane."
        } else if closest.element.kind == .wall {
            guidance = "Turn left or right."
        } else {
            guidance = closest.nearest.y <= 0 ? "Step right to pass." : "Step left to pass."
        }
        return ObstacleAlert(severity: isStairs ? .stop : severity, headline: headline, guidance: guidance,
                             guidanceIcon: .straight, dedupeKey: "indoor-\(closest.element.label)",
                             fragments: [closest.element.label, place, guidance])
    }

    // MARK: Mini map (user at bottom center facing up)

    private static func mapItem(_ item: Placed) -> MiniMapItem? {
        func toMap(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x: 0.5 + p.y / mapSpan, y: 0.81 - p.x / mapSpan)
        }
        let mapped = item.points.map(toMap)
        guard mapped.contains(where: { (-0.1...1.1).contains($0.x) && (-0.1...1.1).contains($0.y) }) else { return nil }

        if item.points.count == 2 {
            // Wall or door: a thin rotated bar.
            let a = mapped[0], b = mapped[1]
            let length = hypot(b.x - a.x, b.y - a.y)
            let thickness = item.element.kind == .wall ? 0.08 : 0.06
            return MiniMapItem(category: item.element.category,
                               rect: CGRect(x: (a.x + b.x) / 2 - length / 2, y: (a.y + b.y) / 2 - thickness / 2,
                                            width: length, height: thickness),
                               rotation: atan2(b.y - a.y, b.x - a.x))
        }
        let xs = mapped.map(\.x), ys = mapped.map(\.y)
        return MiniMapItem(category: item.element.category,
                           rect: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
    }

    // MARK: Wording

    static func steps(_ meters: Double) -> String {
        let count = max(1, Int((meters / stepLength).rounded()))
        return count == 1 ? "1 step" : "\(count) steps"
    }

    static func phrase(for bearing: Double) -> String {
        switch bearing {
        case -15...15: "straight ahead"
        case 15...40: "ahead, on your right"
        case -40 ..< -15: "ahead, on your left"
        case 40...: "to your right"
        default: "to your left"
        }
    }

    private static func side(_ bearing: Double) -> String {
        abs(bearing) <= 15 ? "ahead" : (bearing < 0 ? "left" : "right")
    }

    // MARK: 2D helpers

    private static func nearestPoint(to p: SIMD2<Double>, on points: [SIMD2<Double>]) -> SIMD2<Double> {
        guard points.count > 1 else { return points.first ?? p }
        let edges = zip(points, points.dropFirst() + (points.count > 2 ? [points[0]] : []))
        return edges.map { closest(on: $0, $1, to: p) }.min { simd_length($0 - p) < simd_length($1 - p) } ?? points[0]
    }

    private static func closest(on a: SIMD2<Double>, _ b: SIMD2<Double>, to p: SIMD2<Double>) -> SIMD2<Double> {
        let ab = b - a
        let lengthSquared = (ab * ab).sum()
        guard lengthSquared > 0 else { return a }
        let t = max(0, min(1, ((p - a) * ab).sum() / lengthSquared))
        return a + ab * t
    }

    private static func contains(_ polygon: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Footprint outline sampled every 10 cm, for "is any part of it in the corridor" checks.
    private static func densify(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard points.count > 1 else { return points }
        let edges = Array(zip(points, points.dropFirst() + (points.count > 2 ? [points[0]] : [])))
        return edges.flatMap { a, b -> [SIMD2<Double>] in
            let count = max(1, Int(simd_length(b - a) / 0.1))
            return (0...count).map { a + (b - a) * (Double($0) / Double(count)) }
        }
    }
}

private nonisolated func simd_length(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
