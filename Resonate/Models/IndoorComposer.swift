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
    /// Stable across scan updates (RoomPlan's identifier, or the tracker's for people), so the same
    /// thing is recognized once and only its position updates.
    var id: UUID = UUID()
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

/// Turns a scanned room into what matters for getting around it: what's in the way, where the doors
/// are, a mini map, and a short spoken update. Pure logic, easy to test.
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
        /// On screen: the one thing that matters most right now…
        var headline: String
        /// …and what to do about it.
        var guidance: String
        var guidanceIcon: Maneuver
        var miniMap: [MiniMapItem]
        /// Something right in front of the user (stairs a little sooner): interrupt.
        var alert: ObstacleAlert?
        /// The short spoken update, in pre-recorded pieces…
        var summary: [String]
        /// …and a key that changes only when the update meaningfully changes, not with every step.
        var summaryKey: String
        /// Doors and doorways, best first: in front before behind, open before closed, nearer first.
        var doors: [Placed]
        /// What's worth outlining on the camera view.
        var relevant: Set<UUID>
        /// Rough room size in meters (longer side first), once a few walls have been found.
        var roomSize: (length: Double, width: Double)?
        /// Things close by (not walls or doors), nearest first, for the card.
        var nearby: [Placed] = []
    }

    static let stepLength = 0.7
    static let corridorHalfWidth = 0.45
    /// The mini map shows this many meters across.
    static let mapSpan = 6.0
    /// "Stop" only this close (about one step).
    static let stopDistance = 0.8
    /// Things in the walking path within this distance are mentioned.
    static let pathRange = 2.5
    /// Stairs get a warning a little sooner.
    static let stairsWarning = 2.0
    static let doorRange = 10.0
    /// Things within this distance are "nearby" and worth a mention.
    static let nearbyRange = 3.0
    /// Step counts stop here (about 30 feet); farther is still said as this many.
    static let maxSteps = 15

    static let closedDoorGuidance = "The door is closed. Find the handle to open it."

    static func compose(_ elements: [RoomElement], pose: FloorPose) -> Result {
        let placed = elements.map { place($0, pose: pose) }
        let block = placed.filter { inCorridor($0, within: pathRange) }.min { $0.distance < $1.distance }
        let doors = placed.filter { isDoor($0) && $0.distance <= doorRange }.sorted(by: doorOrder)
        let doorAhead = doors.first { abs($0.bearing) <= 100 }
        // What's around: things (not walls or doors) close by in front or to the side, nearest first.
        let around = placed
            .filter { $0.element.kind == .object && $0.distance <= nearbyRange && abs($0.bearing) <= 100 && $0.element.id != block?.element.id }
            .sorted { $0.distance < $1.distance }

        var headline: String
        var summary: [String]
        var guidance: [String] = []
        var icon = Maneuver.straight
        var key: [String]
        // At most two things in one update: what to do first, then what matters most and what else is close.
        // Keys say what and where, not which scanned element, since the scan renames things as it improves.
        let others: ArraySlice<Placed>

        if let block {
            let sentence = describe(block)
            headline = sentence.joined(separator: " ")
            if isClosedDoor(block) {
                // The door is where they're going: say it's there, then how to open it.
                summary = sentence + [closedDoorGuidance]
                guidance.append(closedDoorGuidance)
            } else if block.element.kind == .wall {
                summary = ["Turn left or right."] + sentence
                guidance.append("Wall ahead. Turn left or right.")
            } else {
                let pass = passSide(block)
                summary = [pass.text] + sentence
                guidance.append(block.distance <= stopDistance ? "Stop. \(pass.text)" : pass.text)
                icon = pass.icon
            }
            key = ["block-\(block.element.label)-\(side(block.bearing))-\(bucket(block.distance))"]
            others = around.prefix(1)
        } else if let door = doorAhead {
            let sentence = describe(door)
            headline = sentence.joined(separator: " ")
            summary = ["Clear ahead."] + sentence + (isClosedDoor(door) ? ["It's closed."] : [])
            guidance.append("Walk straight.")
            key = ["door-\(side(door.bearing))-\(bucket(door.distance))"]
            others = around.prefix(1)
        } else if let first = around.first {
            headline = describe(first).joined(separator: " ")
            summary = ["Clear ahead."]
            guidance.append("Walk straight.")
            key = ["clear"]
            others = around.prefix(2)
        } else {
            headline = "The way ahead is clear."
            summary = ["Clear ahead."]
            guidance.append("Walk straight.")
            key = ["clear"]
            others = []
        }
        // Nearby things are mentioned again only if they change or move to another side, not as you step closer.
        for item in others {
            summary += describe(item)
            key.append("near-\(item.element.label)-\(side(item.bearing))")
        }
        if let side = wallAlongside(placed) {
            guidance.append("Wall stays on your \(side).")
        }

        var relevant = Set(placed.filter { item in
            (isDoor(item) && item.distance <= 8 && abs(item.bearing) <= 100)
                || inCorridor(item, within: 4)
                || (item.element.kind == .object && item.distance <= 4 && abs(item.bearing) <= 70)
                || (item.element.category == .person && item.distance <= 5)
        }.map(\.element.id))
        if let block { relevant.insert(block.element.id) }

        return Result(
            headline: headline,
            guidance: guidance.joined(separator: " "),
            guidanceIcon: icon,
            miniMap: placed.compactMap(mapItem),
            alert: alert(for: placed),
            summary: summary,
            summaryKey: key.joined(separator: "|"),
            doors: doors,
            relevant: relevant,
            roomSize: roomSize(elements),
            nearby: Array(around.prefix(3))
        )
    }

    /// Meters from a floor point (world X/Z) to the nearest part of an element.
    static func distance(from point: SIMD2<Double>, to element: RoomElement) -> Double {
        if element.footprint.count >= 3 && contains(element.footprint, point) { return 0 }
        return simd_length(nearestPoint(to: point, on: element.footprint) - point)
    }

    // MARK: Geometry

    static func place(_ element: RoomElement, pose: FloorPose) -> Placed {
        let points = element.footprint.map(pose.relative)
        let nearest = nearestPoint(to: .zero, on: points)
        let inside = points.count >= 3 && contains(points, .zero)
        return Placed(element: element, points: points, distance: inside ? 0 : simd_length(nearest), nearest: nearest)
    }

    /// The middle of something, relative to the user (x = ahead, y = right): where to aim for a door.
    static func center(of item: Placed) -> SIMD2<Double> {
        item.points.reduce(SIMD2<Double>.zero, +) / Double(max(item.points.count, 1))
    }

    /// The middle of something in world X/Z, to find it again if its identifier changes.
    static func worldCenter(of element: RoomElement) -> SIMD2<Double> {
        element.footprint.reduce(SIMD2<Double>.zero, +) / Double(max(element.footprint.count, 1))
    }

    private static func inCorridor(_ item: Placed, within range: Double) -> Bool {
        guard !isPassable(item) else { return false }
        // Any part of the footprint inside the walking corridor ahead.
        let samples = densify(item.points)
        return samples.contains { $0.x > -0.1 && $0.x <= range && abs($0.y) <= corridorHalfWidth }
    }

    static func isDoor(_ item: Placed) -> Bool {
        if case .door = item.element.kind { return true }
        return item.element.kind == .opening
    }

    /// Open doors and doorways: ways through, not things in the way.
    private static func isPassable(_ item: Placed) -> Bool {
        if case .door(let open) = item.element.kind { return open }
        return item.element.kind == .opening
    }

    static func isClosedDoor(_ item: Placed) -> Bool {
        if case .door(let open) = item.element.kind { return !open }
        return false
    }

    /// In front before behind, ways through before closed doors, then nearer first.
    private static func doorOrder(_ a: Placed, _ b: Placed) -> Bool {
        let aFront = abs(a.bearing) <= 100, bFront = abs(b.bearing) <= 100
        if aFront != bFront { return aFront }
        if isPassable(a) != isPassable(b) { return isPassable(a) }
        return a.distance < b.distance
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

    /// Which way to step around something: toward the side with more room in the corridor.
    private static func passSide(_ item: Placed) -> (text: String, icon: Maneuver) {
        if isStep(item) { return ("Watch the step.", .straight) }
        return item.nearest.y <= 0 ? ("Step right to pass.", .slightRight) : ("Step left to pass.", .slightLeft)
    }

    /// A single step up or down (from the depth sensor), not a flight of stairs.
    private static func isStep(_ item: Placed) -> Bool {
        (item.element.category == .stairs || item.element.category == .dropOff) && !isStairs(item)
    }

    private static func isStairs(_ item: Placed) -> Bool {
        item.element.category == .stairs && item.element.label.hasPrefix("Stairs")
    }

    /// Something right in front: "Stop. Step right to pass. Chair right in front of you."
    /// Stairs a little sooner. Doors never: walking up to a door is the point.
    private static func alert(for placed: [Placed]) -> ObstacleAlert? {
        let stairs = placed.filter { isStairs($0) && inCorridor($0, within: stairsWarning) }
            .min { $0.distance < $1.distance }
        let close = placed.filter { !isDoor($0) && inCorridor($0, within: stopDistance) }.min { $0.distance < $1.distance }
        guard let item = stairs ?? close else { return nil }
        let guidance: String
        if isStairs(item) {
            guidance = "Find the railing."
        } else if item.element.kind == .wall {
            guidance = "Turn left or right."
        } else {
            guidance = passSide(item).text
        }
        let sentence = describe(item)
        // Repeats are by kind of danger, not scanned element (the scan renames things as it improves).
        let kind = isStairs(item) ? "stairs" : item.element.kind == .wall ? "wall" : item.element.category.rawValue
        return ObstacleAlert(severity: .stop, headline: "Stop. \(sentence.joined(separator: " "))", guidance: guidance,
                             guidanceIcon: item.element.kind == .wall ? .straight : passSide(item).icon,
                             dedupeKey: kind, fragments: ["Stop.", guidance] + sentence)
    }

    /// Rough length and width of the room from its walls, measured along the longest wall.
    private static func roomSize(_ elements: [RoomElement]) -> (length: Double, width: Double)? {
        let walls = elements.filter { $0.kind == .wall && $0.footprint.count == 2 }
        guard walls.count >= 3, let longest = walls.max(by: { simd_length($0.footprint[1] - $0.footprint[0]) < simd_length($1.footprint[1] - $1.footprint[0]) })
        else { return nil }
        let along = longest.footprint[1] - longest.footprint[0]
        let length = simd_length(along)
        guard length > 0.5 else { return nil }
        let u = along / length, v = SIMD2(-u.y, u.x)
        let points = walls.flatMap(\.footprint)
        let us = points.map { ($0 * u).sum() }, vs = points.map { ($0 * v).sum() }
        let a = us.max()! - us.min()!, b = vs.max()! - vs.min()!
        guard min(a, b) >= 1 else { return nil }
        return (max(a, b), min(a, b))
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

    /// "Chair 2 steps ahead, on your right." as pieces: ["Chair", "2 steps", "ahead, on your right."].
    static func describe(_ item: Placed) -> [String] {
        [item.element.label] + place(distance: item.distance, bearing: item.bearing)
    }

    static func place(distance: Double, bearing: Double) -> [String] {
        distance <= stopDistance ? ["right in front of you."] : [steps(distance), "\(phrase(for: bearing))."]
    }

    /// How to turn toward something at `bearing` (degrees, positive = right).
    static func turn(toward bearing: Double) -> (text: String, icon: Maneuver) {
        let side = bearing < 0 ? "left" : "right"
        switch abs(bearing) {
        case ...12: return ("Walk straight.", .straight)
        case ...45: return ("Turn slightly \(side).", bearing < 0 ? .slightLeft : .slightRight)
        case ...130: return ("Turn \(side).", bearing < 0 ? .left : .right)
        default: return ("Turn around.", .uTurn)
        }
    }

    /// Distance bands; moving into a closer one is worth mentioning again.
    private static func bucket(_ meters: Double) -> Int {
        switch meters / stepLength {
        case ...2: 0
        case ...4: 1
        case ...7: 2
        default: 3
        }
    }

    static func steps(_ meters: Double) -> String {
        let count = min(maxSteps, max(1, Int((meters / stepLength).rounded())))
        return count == 1 ? "1 step" : "\(count) steps"
    }

    static func phrase(for bearing: Double) -> String {
        if abs(bearing) > 110 { return "behind you" }
        return switch bearing {
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
