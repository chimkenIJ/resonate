import Foundation

/// Decides what to say while walking, like a sighted guide: the way ahead first, then at most two
/// things worth knowing about. Speaks only when something meaningfully changed.
///
/// - Urgent (very close in the path, or coming fast): a short interrupting phrase and a stop buzz, right away.
/// - Important: in the next summary, at most every `summaryInterval` seconds.
/// - Everything else: silent, but still tracked.
///
/// Templates, not a language model: instant, free, offline, and predictable. Pure logic, easy to test.
nonisolated struct WalkNarrator {
    nonisolated enum Output: Equatable, Sendable {
        /// Interrupt now.
        case urgent(ObstacleAlert)
        /// The current picture, for the screen. `speak` is true when it changed enough to say out loud.
        /// `obstacles` are the tracks it mentions, so the screen can keep their distances current.
        case summary(ObstacleAlert, speak: Bool, advice: PathAdvice, obstacles: [UUID])
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

    static let summaryInterval: TimeInterval = 5
    /// With nothing new to say, a short "Path clear." this often.
    static let clearReminderInterval: TimeInterval = 15
    static let pulseCooldown: TimeInterval = 4
    /// The same object isn't announced as urgent again within this time.
    static let urgentCooldown: TimeInterval = 6
    static let maxObstaclesSpoken = 2

    private var startedAt: Date?
    private var lastSummaryAt: Date = .distantPast
    private var lastSpokenKey: String?
    private var lastSpokenAt: Date = .distantPast
    private var advice: PathAdvice = .clear
    private var urgentAnnounced: [UUID: Date] = [:]
    private var lastPulseAt: Date = .distantPast
    private var lastPulseBucket: Int?
    /// On stairs: after the first warning, stairs, curbs, and unnamed obstacles stay quiet until no stairs
    /// have been seen for `stairsQuietTime`. Climbing tilts the phone, which otherwise keeps re-finding them.
    private var stairsQuietUntil: Date?
    static let stairsQuietTime: TimeInterval = 8
    /// True while climbing stairs (see `stairsQuietUntil`), so the screen can hold still too.
    var isOnStairs: Bool { stairsQuietUntil != nil }

    /// The phone is going up or down steps (from its height changing): stay in stairs mode.
    mutating func noteClimbing(now: Date) {
        stairsQuietUntil = now.addingTimeInterval(Self.stairsQuietTime)
    }

    /// - Parameter canSpeak: false while something else is playing; summaries never talk over it.
    mutating func update(tracks all: [TrackedObstacle], clearance: PathClearance?, canSpeak: Bool, now: Date) -> [Output] {
        if startedAt == nil {
            startedAt = now
            lastSummaryAt = now // first summary after a few seconds, not on top of the welcome
        }
        var outputs: [Output] = []

        if let until = stairsQuietUntil {
            if now >= until {
                stairsQuietUntil = nil
            } else if all.contains(where: { $0.category == .stairs && $0.isVisible }) {
                stairsQuietUntil = now.addingTimeInterval(Self.stairsQuietTime)
            }
        }
        let tracks = stairsQuietUntil == nil ? all : all.filter { !Self.isStairsRelated($0) }

        // Urgent: newly urgent only. Everything urgent right now counts as said, so two at once don't stack.
        urgentAnnounced = urgentAnnounced.filter { now.timeIntervalSince($0.value) < Self.urgentCooldown }
        let urgent = tracks.filter { $0.tier == .urgent }
        let fresh = urgent.filter { urgentAnnounced[$0.id] == nil }
        if let first = fresh.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }) {
            outputs.append(.urgent(Self.urgentAlert(for: first, clearance: clearance)))
            if first.category == .stairs { stairsQuietUntil = now.addingTimeInterval(Self.stairsQuietTime) }
        }
        for track in urgent { urgentAnnounced[track.id] = now }

        // Proximity buzz for the nearest thing in the path, only when it gets closer, with a cooldown.
        let nearest = tracks.filter { $0.inPath && $0.tier >= .important }.compactMap(\.distance).min()
        let bucket = nearest.map(Self.bucket)
        if fresh.isEmpty, let bucket, bucket < (lastPulseBucket ?? .max), now.timeIntervalSince(lastPulseAt) >= Self.pulseCooldown {
            outputs.append(.pulse)
            lastPulseAt = now
        }
        if fresh.isEmpty { lastPulseBucket = bucket }

        // Summary every few seconds.
        guard now.timeIntervalSince(lastSummaryAt) >= Self.summaryInterval else { return outputs }
        lastSummaryAt = now
        let important = tracks
            .filter { $0.tier >= .important }
            .sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
            .prefix(Self.maxObstaclesSpoken)
        advice = Self.advice(clearance: clearance, inPath: tracks.filter { $0.inPath && $0.tier >= .important },
                             previous: advice)
        let summary = Self.summary(advice: advice, obstacles: Array(important))
        if important.contains(where: { $0.category == .stairs }) { stairsQuietUntil = now.addingTimeInterval(Self.stairsQuietTime) }
        let key = ([advice.rawValue] + important.map { "\($0.id)-\($0.direction.rawValue)-\(Self.bucket($0.distance ?? 9))" })
            .joined(separator: "|")

        let changed = key != lastSpokenKey
        let reminder = important.isEmpty && advice == .clear && now.timeIntervalSince(lastSpokenAt) >= Self.clearReminderInterval
        let speak = canSpeak && (changed || reminder)
        if speak {
            lastSpokenKey = key
            lastSpokenAt = now
        }
        outputs.append(.summary(summary, speak: speak, advice: advice, obstacles: important.map(\.id)))
        return outputs
    }

    /// Things that keep reappearing while climbing stairs: the stairs themselves, edges, and depth "Obstacle"s.
    private static func isStairsRelated(_ track: TrackedObstacle) -> Bool {
        track.category == .stairs || track.category == .dropOff || track.label == ObstacleTracker.genericLabel
    }

    // MARK: Wording

    /// "Stop. Post straight ahead. Veer left." The last part says which way to go, out loud and on screen.
    static func urgentAlert(for track: TrackedObstacle, clearance: PathClearance? = nil) -> ObstacleAlert {
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
            fragments: ["Stop.", track.label, place, guidance]
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
    static func summary(advice: PathAdvice, obstacles: [TrackedObstacle]) -> ObstacleAlert {
        var headline: [String] = []
        var fragments = [advice.rawValue]
        for track in obstacles {
            guard let distance = track.distance else { continue }
            let pieces = [track.label, "\(track.direction.spoken),", "\(DistanceText.spoken(distance))."]
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
