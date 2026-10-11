import Foundation
import simd

/// A short-lived map of the room, so guidance works from what's been seen rather than only what the
/// camera sees this instant.
///
/// - The room scan (walls, doors, furniture) is kept as the scanner reports it.
/// - Things only the camera or depth sensor found (a box, a cone, a bin) are remembered for `memory`
///   after they were last seen, people only for `peopleMemory`. The same thing found again is merged
///   with what's remembered, not added twice.
/// - Something remembered is forgotten when the camera looks right at where it was and it isn't there,
///   or once the user is `areaRadius` away (they've left the area).
/// - `coverage` is how much of a full circle the user has turned through, for the first look around.
/// - `heading(_:)` is where the user is going: the way they've been walking, or where the phone faces.
///
/// Pure logic, easy to test.
nonisolated struct IndoorMap: Sendable {
    static let memory: TimeInterval = 180
    static let peopleMemory: TimeInterval = 4
    static let areaRadius = 15.0
    /// Found again within this distance (same kind of thing): the same thing.
    static let mergeDistance = 0.5
    /// Looking right at where something was, this long without seeing it: it's gone.
    static let goneAfter: TimeInterval = 1.5
    static let sectors = 12
    /// Moved at least this far in the last `walkingWindow`: walking, and that's the way they're going.
    static let walkingDistance = 0.35
    static let walkingWindow: TimeInterval = 1.5

    private struct Remembered: Sendable {
        var element: RoomElement
        var lastSeen: Date
    }

    private var scanned: [RoomElement] = []
    private var remembered: [UUID: Remembered] = [:]
    private var coveredSectors = Set<Int>()
    private var recentPositions: [(at: Date, position: SIMD2<Double>)] = []

    /// Everything on the map: the room scan, then what's remembered.
    var elements: [RoomElement] { scanned + remembered.values.map(\.element) }

    /// 0...1: how much of a full circle the user has faced while scanning.
    var coverage: Double { Double(coveredSectors.count) / Double(Self.sectors) }

    /// - Parameter live: identifiers of `elements` found by the camera or depth sensor (not the room scan).
    mutating func update(_ elements: [RoomElement], live: Set<UUID>, pose: FloorPose, now: Date) {
        let angle = atan2(pose.forward.y, pose.forward.x)
        coveredSectors.insert(Int(((angle + .pi) / (2 * .pi) * Double(Self.sectors)).rounded(.down)) % Self.sectors)
        recentPositions.append((now, pose.position))
        recentPositions.removeAll { now.timeIntervalSince($0.at) > Self.walkingWindow }

        scanned = elements.filter { !live.contains($0.id) }
        for element in elements where live.contains(element.id) {
            if let id = match(for: element) {
                // Keep the remembered identifier, so it stays one thing.
                var element = element
                element.id = id
                remembered[id] = Remembered(element: element, lastSeen: now)
            } else {
                remembered[element.id] = Remembered(element: element, lastSeen: now)
            }
        }

        remembered = remembered.filter { _, entry in
            let age = now.timeIntervalSince(entry.lastSeen)
            let center = IndoorComposer.worldCenter(of: entry.element)
            if age > (entry.element.category == .person ? Self.peopleMemory : Self.memory) { return false }
            if simd_distance(center, pose.position) > Self.areaRadius { return false }
            // In plain view and close, but not seen lately: it's been moved.
            let relative = pose.relative(center)
            let inView = (0.5...3.5).contains(relative.x) && abs(atan2(relative.y, relative.x)) < 25 * .pi / 180
            return !(inView && age > Self.goneAfter)
        }
    }

    /// Where the user is going, as a pose: the way they've been walking over the last moment, or where
    /// the phone faces when standing still. Steady while walking even as the phone sways.
    func heading(_ pose: FloorPose) -> FloorPose {
        guard let first = recentPositions.first?.position, let last = recentPositions.last?.position else { return pose }
        let moved = last - first
        let distance = simd_length(moved)
        guard distance >= Self.walkingDistance else { return pose }
        let direction = moved / distance
        // Walking backward isn't "going" anywhere on purpose: keep to where the phone faces.
        guard (direction * pose.forward).sum() > cos(100 * Double.pi / 180) else { return pose }
        return FloorPose(position: pose.position, forward: direction)
    }

    /// Something remembered that this is the same thing as: same kind, about the same place.
    private func match(for element: RoomElement) -> UUID? {
        if remembered[element.id] != nil { return element.id }
        let center = IndoorComposer.worldCenter(of: element)
        return remembered.values
            .filter { $0.element.category == element.category }
            .map { ($0.element.id, simd_distance(IndoorComposer.worldCenter(of: $0.element), center)) }
            .filter { $0.1 <= Self.mergeDistance }
            .min { $0.1 < $1.1 }?.0
    }
}
