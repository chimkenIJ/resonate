import Foundation
import simd

/// Decides what to say indoors. It describes what's in front, left to right, and never says where to
/// go: there's no one right way through a room, and only the user knows where they're headed.
/// - "Stop" only for something right in front of them, once: not again for the same kind of danger
///   within `urgentCooldown`, or for the same spot under another name.
/// - What's in front ("Couch 3 steps ahead, on your left. Table 2 steps straight ahead."), but only
///   what hasn't been said: something already mentioned isn't repeated while it's still around, or
///   until it's been out of sight for `repeatAfter`. The same spot counts as the same thing, whatever
///   the scan calls it this time. At most every `summaryInterval` seconds, never over other speech.
/// - The room's size and door count once, when it's known.
/// - "Find door": where the doors are; how to open a closed one right in front.
/// Pure logic, easy to test.
nonisolated struct IndoorNavigator {
    nonisolated enum Output: Equatable, Sendable {
        case urgent(ObstacleAlert)
        /// Spoken update, in pre-recorded pieces where possible.
        case say([String])
        /// At a closed door: describe how to open it (handle, push or pull).
        case describeDoor
        /// No door mapped yet: ask the camera description where one is.
        case lookForDoor
    }

    static let summaryInterval: TimeInterval = 3
    /// The same kind of danger doesn't get another "Stop" until it's been gone this long.
    static let urgentCooldown: TimeInterval = 8
    /// A closed door this close is "the door in front": say how to open it.
    static let atDoorDistance = 1.2
    /// "Find door" mentions at most this many.
    static let maxDoors = 2
    /// Mentioned things come up again only after being out of sight this long.
    static let repeatAfter: TimeInterval = 30
    /// Within this distance (world), it's the same thing.
    static let samePlace = 0.6

    private var startedAt: Date?
    private var lastSummaryAt: Date = .distantPast
    private var urgentSaid: [String: Date] = [:]
    /// Things already said (world X/Z), and when each was last in front of the user.
    private var mentioned: [(center: SIMD2<Double>, seen: Date)] = []
    /// Spots already called out with "Stop".
    private var stopped: [(center: SIMD2<Double>, seen: Date)] = []
    private(set) var overviewSaid = false

    mutating func update(_ scene: IndoorComposer.Result, canSpeak: Bool, now: Date) -> [Output] {
        if startedAt == nil {
            startedAt = now
            lastSummaryAt = now // first update after the welcome, not on top of it
        }
        var outputs: [Output] = []

        mentioned.removeAll { now.timeIntervalSince($0.seen) > Self.repeatAfter }
        stopped.removeAll { now.timeIntervalSince($0.seen) > Self.urgentCooldown }
        urgentSaid = urgentSaid.filter { now.timeIntervalSince($0.value) < Self.urgentCooldown }

        // "Stop": once per kind of danger and per spot, again only after it's been gone a while.
        if let alert = scene.alert {
            let spot = scene.alertPosition
            let sameSpot = spot.flatMap { Self.index(near: $0, in: stopped) }
            if urgentSaid[alert.dedupeKey] == nil, sameSpot == nil {
                outputs.append(.urgent(alert))
                if let spot {
                    stopped.append((spot, now))
                    // It's been said; the next update shouldn't mention it again.
                    if Self.index(near: spot, in: mentioned) == nil { mentioned.append((spot, now)) }
                }
            }
            urgentSaid[alert.dedupeKey] = now
            if let index = sameSpot { stopped[index].seen = now }
        }

        // Once: how big the room is and how many doors.
        if !overviewSaid, canSpeak, let size = scene.roomSize, now.timeIntervalSince(startedAt ?? now) >= 4 {
            overviewSaid = true
            lastSummaryAt = now
            return outputs + [.say([Self.overview(size: size, doors: scene.doors.count)])]
        }

        // What's in front that hasn't been said. Anything already said stays quiet while it's still there.
        var fresh: [IndoorComposer.Placed] = []
        for item in scene.nearby {
            let center = IndoorComposer.worldCenter(of: item.element)
            if let index = Self.index(near: center, in: mentioned) {
                mentioned[index].seen = now
            } else {
                fresh.append(item)
            }
        }
        guard canSpeak, !fresh.isEmpty, now.timeIntervalSince(lastSummaryAt) >= Self.summaryInterval else { return outputs }
        lastSummaryAt = now
        mentioned += fresh.map { (IndoorComposer.worldCenter(of: $0.element), now) }
        let said = fresh.flatMap { IndoorComposer.describe($0) + (IndoorComposer.isClosedDoor($0) ? ["It's closed."] : []) }
        return outputs + [.say(said)]
    }

    private static func index(near point: SIMD2<Double>, in list: [(center: SIMD2<Double>, seen: Date)]) -> Int? {
        list.indices.first { simd_distance(list[$0].center, point) <= samePlace }
    }

    /// "Find door": where the doors are, best first. Right at a closed one, how to open it. None mapped:
    /// ask the camera description to look for one.
    static func findDoor(_ scene: IndoorComposer.Result) -> [Output] {
        guard let first = scene.doors.first else {
            return [.say(["I haven't found a door yet."]), .lookForDoor]
        }
        if IndoorComposer.isClosedDoor(first), first.distance <= atDoorDistance {
            return [.say(IndoorComposer.describe(first) + [IndoorComposer.closedDoorGuidance]), .describeDoor]
        }
        let doors = scene.doors.prefix(maxDoors).flatMap { door in
            IndoorComposer.describe(door) + (IndoorComposer.isClosedDoor(door) ? ["It's closed."] : [])
        }
        return [.say(doors)]
    }

    /// "This room is about 20 by 15 feet, with 2 doors."
    static func overview(size: (length: Double, width: Double), doors: Int) -> String {
        func feet(_ meters: Double) -> Int { max(5, Int((meters * DistanceText.feetPerMeter / 5).rounded()) * 5) }
        let doorText = switch doors {
        case 0: "No doors found yet."
        case 1: "with 1 door."
        default: "with \(doors) doors."
        }
        let room = "This room is about \(feet(size.length)) by \(feet(size.width)) feet"
        return doors == 0 ? "\(room). \(doorText)" : "\(room), \(doorText)"
    }
}
