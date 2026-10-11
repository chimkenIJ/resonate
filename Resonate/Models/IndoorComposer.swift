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
        /// Where that is (world X/Z), so the same thing isn't called out twice under another name.
        var alertPosition: SIMD2<Double>?
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
        /// Everything it was composed from (world X/Z) and where the user stood, for planning a route.
        var elements: [RoomElement] = []
        var pose = FloorPose(position: .zero, forward: SIMD2(1, 0))
    }

    static let stepLength = 0.7
    static let corridorHalfWidth = 0.45
    /// The mini map shows this many meters across.
    static let mapSpan = 6.0
    /// "Stop" only this close (about one step).
    static let stopDistance = 0.8
    /// Stairs get a warning a little sooner.
    static let stairsWarning = 2.0
    static let doorRange = 10.0
    /// Step counts stop here (about 30 feet); farther is still said as this many.
    static let maxSteps = 15

    static let closedDoorGuidance = "The door is closed. Find the handle to open it."

    /// What's in front is said within this distance…
    static let frontRange = 4.0
    /// …and this many degrees either side of where the user is going.
    static let frontAngle = 60.0
    /// Doors in front are mentioned a little farther out.
    static let frontDoorRange = 6.0
    /// At most this many things in one update.
    static let maxMentioned = 3

    /// Describes what's in front, left to right ("Couch 3 steps ahead, on your left. Table 2 steps
    /// straight ahead."). Never says where to go: there's no one right way through a room.
    static func compose(_ elements: [RoomElement], pose: FloorPose) -> Result {
        let placed = elements.map { place($0, pose: pose) }
        let doors = placed.filter { isDoor($0) && $0.distance <= doorRange }.sorted(by: doorOrder)
        // Things and doors in front; a wall only when it's close and straight ahead (walls run alongside everywhere).
        let front = placed.filter { item in
            guard abs(item.bearing) <= frontAngle else { return false }
            switch item.element.kind {
            case .wall: return item.distance <= 2.5 && abs(item.bearing) <= 20
            case .object: return item.distance <= frontRange
            case .door, .opening: return item.distance <= frontDoorRange
            }
        }
        // The nearest few, said left to right.
        let mentioned = Array(front.sorted { $0.distance < $1.distance }.prefix(maxMentioned).sorted { $0.bearing < $1.bearing })

        let sentences = mentioned.map { describe($0) + (isClosedDoor($0) ? ["It's closed."] : []) }
        let summary = sentences.isEmpty ? ["Clear ahead."] : sentences.flatMap { $0 }
        // Said again only when what's in front, or which side it's on, changes, not with every step closer.
        let key = mentioned.isEmpty ? "clear" : mentioned.map { "\($0.element.label)-\(side($0.bearing))" }.joined(separator: "|")
        let headline = switch mentioned.count {
        case 0: "Nothing in front of you."
        case 1: sentences[0].joined(separator: " ")
        default: "Left to right: " + mentioned.map(\.element.label).joined(separator: ", ") + "."
        }
        let stop = alert(for: placed)
        let stopItem = stopTarget(placed)

        var relevant = Set(mentioned.map(\.element.id))
        relevant.formUnion(placed.filter { item in
            (isDoor(item) && item.distance <= 8 && abs(item.bearing) <= 100)
                || (item.element.category == .person && item.distance <= 5)
        }.map(\.element.id))

        return Result(
            headline: headline,
            guidance: sentences.isEmpty ? "Clear ahead." : sentences.map { $0.joined(separator: " ") }.joined(separator: " "),
            guidanceIcon: .straight,
            miniMap: placed.compactMap(mapItem),
            alert: stop,
            alertPosition: stopItem.map { worldCenter(of: $0.element) },
            summary: summary,
            summaryKey: key,
            doors: doors,
            relevant: relevant,
            roomSize: roomSize(elements),
            nearby: mentioned,
            elements: elements,
            pose: pose
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




    private static func isStairs(_ item: Placed) -> Bool {
        item.element.category == .stairs && item.element.label.hasPrefix("Stairs")
    }

    /// Something right in front: "Stop. Chair right in front of you." Stairs a little sooner, with
    /// "Find the railing." Doors never: walking up to a door is the point.
    private static func alert(for placed: [Placed]) -> ObstacleAlert? {
        guard let item = stopTarget(placed) else { return nil }
        let railing = isStairs(item) ? ["Find the railing."] : []
        let sentence = describe(item)
        // Repeats are by kind of danger, not scanned element (the scan renames things as it improves).
        let kind = isStairs(item) ? "stairs" : item.element.kind == .wall ? "wall" : item.element.category.rawValue
        return ObstacleAlert(severity: .stop, headline: "Stop. \(sentence.joined(separator: " "))", guidance: railing.first ?? "",
                             guidanceIcon: .straight, dedupeKey: kind, fragments: ["Stop."] + sentence + railing)
    }

    /// What a "Stop" would be about: stairs a little ahead, or anything (not a door) right in front.
    private static func stopTarget(_ placed: [Placed]) -> Placed? {
        let stairs = placed.filter { isStairs($0) && inCorridor($0, within: stairsWarning) }
            .min { $0.distance < $1.distance }
        let close = placed.filter { !isDoor($0) && inCorridor($0, within: stopDistance) }.min { $0.distance < $1.distance }
        return stairs ?? close
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
