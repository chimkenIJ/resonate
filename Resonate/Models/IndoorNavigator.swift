import Foundation

/// Decides what to say indoors, so the user hears what helps them get around and nothing else:
/// - "Stop" only for something right in front of them, once.
/// - A short update only when the situation changes ("Door 5 steps ahead, on your left."),
///   at most every `summaryInterval` seconds.
/// - The room's size and door count once, when it's known.
/// - Guiding to a door: which way to turn, a tap when facing it, and when they've reached it.
/// Pure logic, easy to test.
nonisolated struct IndoorNavigator {
    nonisolated enum Output: Equatable, Sendable {
        case urgent(ObstacleAlert)
        /// Spoken update, in pre-recorded pieces where possible.
        case say([String])
        /// Facing the door being guided to: one light tap.
        case aligned
        /// Reached a closed door: describe how to open it (handle, push or pull).
        case describeDoor
        /// No door mapped yet: ask the camera description where one is.
        case lookForDoor
    }

    nonisolated enum Guide: Equatable, Sendable {
        /// No door found yet; waiting for one to come into view.
        case searching(since: Date)
        /// Guiding to a door, remembered by identifier and where it is.
        case toDoor(id: UUID, center: SIMD2<Double>)
    }

    static let summaryInterval: TimeInterval = 5
    /// The same thing doesn't get another "Stop" until it's been gone this long.
    static let urgentCooldown: TimeInterval = 8
    /// Guidance repeats at most this often, and only when the turn or the distance changed.
    static let guideInterval: TimeInterval = 3
    /// Within this distance the user is at the door.
    static let arriveDistance = 0.9
    /// Facing the door within this many degrees: a tap.
    static let alignedBearing = 10.0
    /// Still no door after this long: ask the camera description.
    static let searchTimeout: TimeInterval = 6

    private(set) var guide: Guide?
    private var startedAt: Date?
    private var lastSummaryKey: String?
    private var lastSummaryAt: Date = .distantPast
    private var urgentSaid: [String: Date] = [:]
    private var guideSaidTurn: String?
    private var guideSaidSteps = Int.max
    private var guideSaidAt: Date = .distantPast
    private var isAligned = false
    private var askedCamera = false
    private(set) var overviewSaid = false

    /// What the screen shows while guiding.
    private(set) var guideHeadline: String?
    private(set) var guideGuidance: String?
    private(set) var guideIcon: Maneuver = .straight
    /// The last thing said while guiding, for "Repeat".
    private(set) var lastGuide: [String]?

    var isGuiding: Bool { guide != nil }
    var guideTarget: UUID? {
        if case .toDoor(let id, _) = guide { return id }
        return nil
    }

    mutating func update(_ scene: IndoorComposer.Result, canSpeak: Bool, now: Date) -> [Output] {
        if startedAt == nil {
            startedAt = now
            lastSummaryAt = now // first update after the welcome, not on top of it
        }
        var outputs: [Output] = []

        // "Stop": once per thing, again only after it's been gone a while.
        urgentSaid = urgentSaid.filter { now.timeIntervalSince($0.value) < Self.urgentCooldown }
        if let alert = scene.alert {
            if urgentSaid[alert.dedupeKey] == nil { outputs.append(.urgent(alert)) }
            urgentSaid[alert.dedupeKey] = now
        }

        // Guiding replaces the regular updates.
        if guide != nil { return outputs + updateGuide(scene, now: now) }

        // Once: how big the room is and how many doors.
        if !overviewSaid, canSpeak, let size = scene.roomSize, now.timeIntervalSince(startedAt ?? now) >= 4 {
            overviewSaid = true
            lastSummaryAt = now
            return outputs + [.say([Self.overview(size: size, doors: scene.doors.count)])]
        }

        guard canSpeak, scene.summaryKey != lastSummaryKey, now.timeIntervalSince(lastSummaryAt) >= Self.summaryInterval
        else { return outputs }
        lastSummaryKey = scene.summaryKey
        lastSummaryAt = now
        return outputs + [.say(scene.summary)]
    }

    // MARK: Guiding to a door

    mutating func startGuiding(_ scene: IndoorComposer.Result, now: Date) -> [Output] {
        resetGuide()
        guard let door = scene.doors.first else {
            guide = .searching(since: now)
            guideHeadline = "Looking for a door."
            guideGuidance = "Turn slowly in a circle."
            guideIcon = .uTurn
            return [.say(remember(["I haven't found a door yet.", "Turn slowly, and I'll tell you when I see one."]))]
        }
        guide = .toDoor(id: door.element.id, center: IndoorComposer.worldCenter(of: door.element))
        return guideTo(door, now: now, force: true)
    }

    mutating func stopGuiding() {
        resetGuide()
    }

    private mutating func resetGuide() {
        guide = nil
        guideHeadline = nil
        guideGuidance = nil
        guideIcon = .straight
        guideSaidTurn = nil
        guideSaidSteps = .max
        guideSaidAt = .distantPast
        isAligned = false
        askedCamera = false
        lastGuide = nil
    }

    private mutating func updateGuide(_ scene: IndoorComposer.Result, now: Date) -> [Output] {
        switch guide {
        case .searching(let since):
            if let door = scene.doors.first {
                guide = .toDoor(id: door.element.id, center: IndoorComposer.worldCenter(of: door.element))
                return [.say(remember(["Found a door."]))] + guideTo(door, now: now, force: true)
            }
            if !askedCamera, now.timeIntervalSince(since) >= Self.searchTimeout {
                askedCamera = true
                return [.lookForDoor]
            }
            return []
        case .toDoor(let id, let center):
            // Same door by identifier, or whatever door is now where it was (identifiers can change as the scan improves).
            let door = scene.doors.first { $0.element.id == id }
                ?? scene.doors.first { length(IndoorComposer.worldCenter(of: $0.element) - center) < 1 }
            guard let door else {
                guide = .searching(since: now)
                askedCamera = false
                guideHeadline = "Looking for the door."
                guideGuidance = "Turn slowly in a circle."
                guideIcon = .uTurn
                return [.say(remember(["I lost the door.", "Turn slowly, and I'll tell you when I see one."]))]
            }
            guide = .toDoor(id: door.element.id, center: IndoorComposer.worldCenter(of: door.element))
            return guideTo(door, now: now, force: false)
        case nil:
            return []
        }
    }

    private mutating func guideTo(_ door: IndoorComposer.Placed, now: Date, force: Bool) -> [Output] {
        // Aim for the middle of the door, not its nearest edge.
        let middle = IndoorComposer.center(of: door)
        let distance = length(middle)
        let bearing = atan2(middle.y, middle.x) * 180 / .pi
        let name = door.element.label

        if distance <= Self.arriveDistance {
            let closed = IndoorComposer.isClosedDoor(door)
            let said: [String]
            if door.element.kind == .opening {
                said = ["You're at the doorway.", "Walk straight through."]
            } else if closed {
                said = ["You're at the door.", IndoorComposer.closedDoorGuidance]
            } else {
                said = ["You're at the door.", "It's open."]
            }
            resetGuide()
            lastGuide = said
            return [.say(said)] + (closed ? [.describeDoor] : [])
        }

        let place = IndoorComposer.place(distance: distance, bearing: bearing)
        let turn = IndoorComposer.turn(toward: bearing)
        guideHeadline = ([name] + place).joined(separator: " ")
        guideGuidance = turn.text
        guideIcon = turn.icon

        var outputs: [Output] = []
        // A tap when turning to face the door (with a little hysteresis so it doesn't buzz on the edge).
        let facing = abs(bearing) <= (isAligned ? Self.alignedBearing * 1.8 : Self.alignedBearing)
        if facing && !isAligned { outputs.append(.aligned) }
        isAligned = facing

        let steps = Int((distance / IndoorComposer.stepLength).rounded())
        let changed = turn.text != guideSaidTurn || steps <= guideSaidSteps - 3
        if force || (changed && now.timeIntervalSince(guideSaidAt) >= Self.guideInterval) {
            guideSaidTurn = turn.text
            guideSaidSteps = steps
            guideSaidAt = now
            outputs.append(.say(remember([name] + place + [turn.text])))
        }
        return outputs
    }

    private mutating func remember(_ said: [String]) -> [String] {
        lastGuide = said
        return said
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

    private func length(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
}
