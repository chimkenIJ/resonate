import Foundation

/// Decides what to say while walking, like a sighted guide: what to do first, then at most two
/// things around the user ("Veer left. Person on your right, 6 feet."). Speaks only when something
/// meaningfully changed.
///
/// - Reports cover everything seen over the last `reportWindow` seconds, so a phone swinging around
///   doesn't produce a new report every frame. Each one is read out in full before the next.
/// - Urgent (very close in the path, or coming fast): right away, in the same format ("Stop. Veer left.
///   Post straight ahead. Person on your right, 6 feet."), with a stop buzz. The same kind of danger isn't
///   called out again within `urgentCooldown` unless it gets closer, however the camera re-finds it.
/// - Everything else: silent, but still tracked.
///
/// Templates, not a language model: instant, free, offline, and predictable. Pure logic, easy to test.
nonisolated struct WalkNarrator {
    nonisolated enum Output: Equatable, Sendable {
        /// Interrupt now.
        case urgent(ObstacleAlert)
        /// The current picture, for the screen, and `say`: only what's new since the last report (the
        /// advice if it changed, things not mentioned lately), nil when there's nothing new.
        /// `obstacles` are the tracks the screen shows, so it can keep their distances current.
        case summary(ObstacleAlert, say: ObstacleAlert?, advice: PathAdvice, obstacles: [UUID])
        /// One light tap: the nearest thing in the path got closer.
        case pulse
    }

    nonisolated enum PathAdvice: String, Sendable {
        case clear = "Path clear."
        case veerLeft = "Veer left."
        case veerRight = "Veer right."
        case blocked = "Path blocked ahead."

        var icon: Maneuver {
            switch self {
            case .clear, .blocked: .straight
            case .veerLeft: .slightLeft
            case .veerRight: .slightRight
            }
        }
    }

    /// How long to look before reporting, and the shortest time between reports.
    static let reportWindow: TimeInterval = 2
    /// Something already mentioned isn't mentioned again while it's still around, or until it's been
    /// out of sight this long (unless it gets closer while in the way).
    static let repeatAfter: TimeInterval = 20
    static let pulseCooldown: TimeInterval = 4
    /// The same kind of danger isn't called out again within this time unless it gets closer.
    static let urgentCooldown: TimeInterval = 8
    /// Even when it gets closer, not more often than this.
    static let urgentMinGap: TimeInterval = 3
    static let maxObstaclesSpoken = 2

    private var startedAt: Date?
    private var lastReportAt: Date = .distantPast
    /// What's been said, by kind and side: how close it was then, and when it was last seen.
    private var mentioned: [String: (bucket: Int, seen: Date)] = [:]
    private var spokenAdvice: PathAdvice?
    private var advice: PathAdvice = .clear
    /// What's been seen lately (important or urgent), and when, by track.
    private var recentlySeen: [UUID: (track: TrackedObstacle, at: Date)] = [:]
    /// Dangers already called out, by kind: how close it was then, when it was said, and when it was last seen.
    private var saidDangers: [String: (bucket: Int, said: Date, seen: Date)] = [:]
    private var lastPulseAt: Date = .distantPast
    private var lastPulseBucket: Int?
    /// On stairs: after the first warning, stairs, curbs, and unnamed obstacles stay quiet until no stairs
    /// have been seen for `stairsQuietTime`. Climbing tilts the phone, which otherwise keeps re-finding them.
    private var stairsQuietUntil: Date?
    private var stairsQuietSince: Date?
    private var lastClimbAt: Date = .distantPast
    static let stairsQuietTime: TimeInterval = 8
    /// Stairs only keep the quiet going when they're right at the user's feet.
    static let stairsAtFeet = 1.5
    /// Without actual climbing, stairs mode ends after this long no matter what the depth sensor sees.
    static let stairsMaxQuiet: TimeInterval = 45
    /// When stairs were last seen nearby, so climbing can be told apart from lifting the phone.
    private(set) var lastStairsSeen: Date = .distantPast
    /// True while climbing stairs (see `stairsQuietUntil`), so the screen can hold still too.
    var isOnStairs: Bool { stairsQuietUntil != nil }

    /// The phone is going up or down steps (from its height changing): stay in stairs mode.
    mutating func noteClimbing(now: Date) {
        if stairsQuietUntil == nil { stairsQuietSince = now }
        stairsQuietUntil = now.addingTimeInterval(Self.stairsQuietTime)
        lastClimbAt = now
    }

    /// - Parameter canSpeak: false while something else is playing; summaries never talk over it.
    mutating func update(tracks all: [TrackedObstacle], clearance: PathClearance?, canSpeak: Bool, now: Date) -> [Output] {
        if startedAt == nil {
            startedAt = now
            lastReportAt = now // first report after a look around, not on top of the welcome
        }
        var outputs: [Output] = []

        if all.contains(where: { $0.category == .stairs && $0.isVisible && $0.isConfirmed && ($0.distance ?? 9) <= 4 }) {
            lastStairsSeen = now
        }
        if let until = stairsQuietUntil {
            let climbing = now.timeIntervalSince(lastClimbAt) < Self.stairsQuietTime
            let tooLong = now.timeIntervalSince(stairsQuietSince ?? now) >= Self.stairsMaxQuiet && !climbing
            if now >= until || tooLong {
                stairsQuietUntil = nil
                stairsQuietSince = nil
            } else if all.contains(where: { $0.category == .stairs && $0.isVisible && ($0.distance ?? 9) <= Self.stairsAtFeet }) {
                stairsQuietUntil = now.addingTimeInterval(Self.stairsQuietTime)
            }
        }
        let tracks = stairsQuietUntil == nil ? all : all.filter { !Self.isStairsRelated($0) }

        // What's been seen over the last couple of seconds, one entry per thing, nearest first.
        for track in tracks where track.isVisible && track.tier >= .important { recentlySeen[track.id] = (track, now) }
        recentlySeen = recentlySeen.filter { now.timeIntervalSince($0.value.at) <= Self.reportWindow }
        let recent = Self.distinct(recentlySeen.values.map(\.track))
        // Anything already mentioned that's still around stays quiet.
        mentioned = mentioned.filter { now.timeIntervalSince($0.value.seen) < Self.repeatAfter }
        for track in recent { mentioned[Self.mentionKey(track)]?.seen = now }

        // Urgent: right away, once per kind of danger (a new camera track of the same thing doesn't count).
        let urgent = tracks.filter { $0.tier == .urgent }
        saidDangers = saidDangers.filter { now.timeIntervalSince($0.value.seen) < Self.urgentCooldown }
        let fresh = urgent.filter { track in
            guard let said = saidDangers[Self.dangerKey(track)] else { return true }
            // It got closer, and the last warning wasn't just now.
            return Self.bucket(track.distance ?? 9) < said.bucket && now.timeIntervalSince(said.said) >= Self.urgentMinGap
        }
        if let first = fresh.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }) {
            // Then what else is around (not the same thing found twice).
            let others = recent.filter { $0.id != first.id && $0.label != first.label }
                .prefix(Self.maxObstaclesSpoken - 1)
            outputs.append(.urgent(Self.urgentAlert(for: first, clearance: clearance, others: Array(others))))
            if first.category == .stairs { startStairsQuiet(now) }
            saidDangers[Self.dangerKey(first)] = (Self.bucket(first.distance ?? 9), now, now)
            // What the alert said counts as said, so the next report doesn't repeat it.
            lastReportAt = now
            for track in [first] + others { mentioned[Self.mentionKey(track)] = (Self.bucket(track.distance ?? 9), now) }
            advice = Self.advice(clearance: clearance, inPath: recent.filter(\.inPath), previous: advice)
            spokenAdvice = advice
        }
        // Everything urgent right now counts as said, so two at once don't stack and one that stays
        // in front isn't repeated.
        for track in urgent {
            let key = Self.dangerKey(track)
            let said = saidDangers[key]
            saidDangers[key] = (said?.bucket ?? Self.bucket(track.distance ?? 9), said?.said ?? now, now)
        }

        // Proximity buzz for the nearest thing in the path, only when it gets closer, with a cooldown.
        let nearest = tracks.filter { $0.inPath && $0.tier >= .important }.compactMap(\.distance).min()
        let bucket = nearest.map(Self.bucket)
        if fresh.isEmpty, let bucket, bucket < (lastPulseBucket ?? .max), now.timeIntervalSince(lastPulseAt) >= Self.pulseCooldown {
            outputs.append(.pulse)
            lastPulseAt = now
        }
        if fresh.isEmpty { lastPulseBucket = bucket }

        // A report from the last couple of seconds: what to do, then what's around, but only what's new.
        guard now.timeIntervalSince(lastReportAt) >= Self.reportWindow else { return outputs }
        let shown = Array(recent.prefix(Self.maxObstaclesSpoken))
        advice = Self.advice(clearance: clearance, inPath: recent.filter(\.inPath), previous: advice)
        let summary = Self.summary(advice: advice, obstacles: shown)
        if shown.contains(where: { $0.category == .stairs }) { startStairsQuiet(now) }

        let newAdvice = advice != spokenAdvice
        let newThings = Array(recent.filter(isNew).prefix(Self.maxObstaclesSpoken))
        var say: ObstacleAlert?
        if canSpeak, newAdvice || !newThings.isEmpty {
            say = Self.summary(advice: advice, obstacles: newThings, sayAdvice: newAdvice)
            spokenAdvice = advice
            for track in newThings { mentioned[Self.mentionKey(track)] = (Self.bucket(track.distance ?? 9), now) }
        }
        // While something else is being read, report as soon as it finishes.
        if canSpeak { lastReportAt = now }
        outputs.append(.summary(summary, say: say, advice: advice, obstacles: shown.map(\.id)))
        return outputs
    }

    /// Not mentioned lately, or in the way and closer than when it was.
    private func isNew(_ track: TrackedObstacle) -> Bool {
        guard let said = mentioned[Self.mentionKey(track)] else { return true }
        return track.inPath && Self.bucket(track.distance ?? 9) < said.bucket
    }

    /// The same kind of thing on the same side is the same thing, however the camera found it.
    static func mentionKey(_ track: TrackedObstacle) -> String {
        "\(track.label)|\(side(track.direction))"
    }

    /// One entry per thing, nearest first: the same kind of thing on the same side is one thing,
    /// even when a swinging camera found it twice.
    static func distinct(_ tracks: [TrackedObstacle]) -> [TrackedObstacle] {
        var nearest: [String: TrackedObstacle] = [:]
        for track in tracks {
            let key = "\(track.label)|\(side(track.direction))"
            if let other = nearest[key], (other.distance ?? .infinity) <= (track.distance ?? .infinity) { continue }
            nearest[key] = track
        }
        return nearest.values.sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
    }

    /// The kind of danger: a post and a sign are both "something in the way"; a drop-off, stairs,
    /// or something coming toward the user are each their own.
    static func dangerKey(_ track: TrackedObstacle) -> String {
        track.isApproaching ? "approaching" : track.category.rawValue
    }

    private static func side(_ direction: RelativeDirection) -> String {
        switch direction {
        case .left, .slightlyLeft: "left"
        case .ahead: "ahead"
        case .slightlyRight, .right: "right"
        }
    }

    private mutating func startStairsQuiet(_ now: Date) {
        if stairsQuietUntil == nil { stairsQuietSince = now }
        stairsQuietUntil = now.addingTimeInterval(Self.stairsQuietTime)
    }

    /// Things that keep reappearing while climbing stairs: the stairs themselves, edges, and depth "Obstacle"s.
    private static func isStairsRelated(_ track: TrackedObstacle) -> Bool {
        track.category == .stairs || track.category == .dropOff || track.label == ObstacleTracker.genericLabel
    }

    // MARK: Wording

    /// "Stop. Veer left. Post straight ahead." Out loud, what to do comes right after "Stop.", then what
    /// it's about; something moving keeps "Wait for it to pass." last so "it" makes sense.
    /// `others` are added after it, the way a summary says them ("Person on your right, 6 feet.").
    static func urgentAlert(for track: TrackedObstacle, clearance: PathClearance? = nil, others: [TrackedObstacle] = []) -> ObstacleAlert {
        let place: String
        let guidance: String
        var icon = Maneuver.straight
        if track.isApproaching {
            place = track.approachSide.map { "approaching from the \($0 == .left ? "left" : "right")." } ?? "coming toward you."
            guidance = "Wait for it to pass."
        } else {
            place = "\(track.direction.spoken)."
            switch track.category {
            case .dropOff: guidance = "Watch the edge."
            case .stairs where track.label.hasPrefix("Stairs"): guidance = "Find the railing."
            case .stairs: guidance = "Watch the step."
            default:
                let way = passingSide(for: track, clearance: clearance)
                guidance = way?.rawValue ?? "Turn left or right."
                icon = way?.icon ?? .straight
            }
        }
        return ObstacleAlert(
            severity: .stop,
            headline: "Stop. \(track.label) \(place)",
            guidance: guidance,
            guidanceIcon: icon,
            dedupeKey: track.id.uuidString,
            fragments: (track.isApproaching ? ["Stop.", track.label, place, guidance] : ["Stop.", guidance, track.label, place])
                + others.flatMap(observation)
        )
    }

    /// Which way to step around something close: the side with more room (LiDAR), otherwise away
    /// from it. Nil when both sides are blocked.
    static func passingSide(for track: TrackedObstacle, clearance: PathClearance?) -> PathAdvice? {
        let away: PathAdvice = (track.lateral ?? 0) >= 0 ? .veerLeft : .veerRight
        guard let clearance else { return away }
        let distance = track.distance ?? 0
        let left = clearance.left ?? .infinity, right = clearance.right ?? .infinity
        let leftOpen = left > distance + 0.5, rightOpen = right > distance + 0.5
        switch (leftOpen, rightOpen) {
        case (true, true): return left == right ? away : (left > right ? .veerLeft : .veerRight)
        case (true, false): return .veerLeft
        case (false, true): return .veerRight
        case (false, false): return nil
        }
    }

    /// "Path clear. Person on your right, 2 meters."
    /// `sayAdvice` false leaves out the advice (it hasn't changed since it was said).
    static func summary(advice: PathAdvice, obstacles: [TrackedObstacle], sayAdvice: Bool = true) -> ObstacleAlert {
        var headline: [String] = []
        var fragments = sayAdvice ? [advice.rawValue] : []
        for track in obstacles {
            let pieces = observation(track)
            guard !pieces.isEmpty else { continue }
            headline.append(pieces.joined(separator: " "))
            fragments += pieces
        }
        let quiet = headline.isEmpty && advice == .clear
        return ObstacleAlert(
            severity: quiet ? .info : .headsUp,
            headline: headline.isEmpty ? (quiet ? "Path looks clear ahead." : "Something is in the way ahead.")
                : headline.joined(separator: " "),
            guidance: advice.rawValue,
            guidanceIcon: advice.icon,
            dedupeKey: "summary",
            fragments: fragments
        )
    }

    /// "Person" "on your right," "6 feet." — pre-recorded pieces, so it plays instantly.
    static func observation(_ track: TrackedObstacle) -> [String] {
        guard let distance = track.distance else { return [] }
        return [track.label, "\(track.direction.spoken),", "\(DistanceText.spoken(distance))."]
    }

    /// Which way to go. With LiDAR, from how much room there is straight ahead and to each side;
    /// otherwise from the obstacles in the path. Hysteresis keeps it from flipping.
    static func advice(clearance: PathClearance?, inPath: [TrackedObstacle], previous: PathAdvice) -> PathAdvice {
        let ahead: Double
        var left = Double.infinity, right = Double.infinity
        if let clearance {
            ahead = clearance.center ?? .infinity
            left = clearance.left ?? .infinity
            right = clearance.right ?? .infinity
        } else if let block = inPath.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }),
                  let distance = block.distance {
            ahead = distance
            // Pass on the side away from it.
            if (block.lateral ?? 0) >= 0 { right = distance } else { left = distance }
        } else {
            ahead = .infinity
        }

        let clearBeyond = previous == .clear ? 2.5 : 3.0
        if ahead > clearBeyond { return .clear }
        if max(left, right) >= ahead + 0.75 {
            if left == right { return previous == .veerRight ? .veerRight : .veerLeft }
            return left > right ? .veerLeft : .veerRight
        }
        return .blocked
    }

    /// Distance bands; moving into a closer one is worth mentioning again.
    static func bucket(_ distance: Double) -> Int {
        switch distance {
        case ...1.5: 0
        case ...2: 1
        case ...3: 2
        default: 3
        }
    }
}
