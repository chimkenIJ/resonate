import CoreGraphics
import Foundation

/// One thing being followed across frames. It's recognized once, then only its position updates.
nonisolated struct TrackedObstacle: Identifiable, Sendable {
    nonisolated enum Tier: Int, Comparable, Sendable {
        /// Tracked, never spoken.
        case background
        /// Goes in the next summary.
        case important
        /// Interrupts right away: very close in the path, or coming toward the user fast.
        case urgent

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: UUID
    var label: String
    var category: ObjectCategory
    var boundingBox: CGRect
    var worldPosition: SIMD3<Double>?
    /// Meters ahead along the user's heading, and to the right of it.
    var forward: Double?
    var lateral: Double?
    var direction: RelativeDirection
    var lastSeen: Date
    /// How often each name was seen. The track keeps the most common one, so it doesn't switch
    /// names when one frame guesses differently.
    var labelVotes: [String: Int] = [:]
    /// Whether it was found in each of the last few frames (newest last).
    var hits: [Bool] = [true]
    var isConfirmed = false
    var inPath = false
    /// Meters per second toward the user from its own movement (positive = coming closer).
    var closingSpeed = 0.0
    var isApproaching = false
    var tier: Tier = .background

    var isVisible: Bool { hits.last == true }

    /// Straight-line distance on the ground.
    var distance: Double? {
        guard let forward else { return nil }
        return (forward * forward + (lateral ?? 0) * (lateral ?? 0)).squareRoot()
    }

    /// "Coming from the right" when it's off to one side, nil when it's in front.
    var approachSide: RelativeDirection? {
        guard let lateral else { return nil }
        if lateral > 0.4 { return .right }
        if lateral < -0.4 { return .left }
        return nil
    }

    var object: DetectedObject {
        DetectedObject(id: id, label: label, category: category, confidence: 1, boundingBox: boundingBox,
                       distanceMeters: distance, lateralMeters: lateral, worldPosition: worldPosition)
    }
}

/// Follows detections from frame to frame so each object is recognized once and then updated by
/// position, instead of being re-detected and re-announced every frame.
/// Pure logic, so it is easy to test.
nonisolated struct ObstacleTracker {
    /// Frames remembered per object; it must appear in `confirmHits` of them before it counts (kills flicker).
    static let window = 5
    static let confirmHits = 3
    /// Seconds to remember something after it leaves the camera view.
    static let keepAlive: TimeInterval = 3

    /// Half-width of the walking corridor. Entering needs `pathEnter`; leaving needs `pathExit` (hysteresis).
    static let pathEnter = 0.6
    static let pathExit = 0.8
    static let alertRange = 4.0
    /// Small things (chairs, signs) only matter this close.
    static let minorRange = 2.5
    static let stopRange = 1.5
    static let edgeStopRange = 2.0
    /// Things coming toward the user are watched farther out.
    static let approachRange = 6.0
    /// Approaching means moving toward the user this fast on its own (LiDAR), or closing this fast
    /// overall when only the size estimate is available (faster than someone walks).
    /// Off for now: too many false alarms in testing. The speed is still measured.
    static let detectsApproaching = false
    static let approachSpeedWorld = 0.9
    static let approachSpeedEstimated = 2.2

    /// When the camera can't measure sideways position, assume roughly this horizontal field of view.
    private static let fallbackHalfFOVTangent = 0.45

    private(set) var tracks: [TrackedObstacle] = []

    @discardableResult
    mutating func update(with frame: DetectionFrame, now: Date) -> [TrackedObstacle] {
        let observations = frame.objects
        var matchedTrack = Set<Int>(), matchedObservation = Set<Int>()

        // Greedy matching: best pairs first, same label only.
        var pairs: [(track: Int, observation: Int, score: Double)] = []
        for (t, track) in tracks.enumerated() {
            for (o, observation) in observations.enumerated() {
                let related = Self.canMatch(track, observation)
                if let score = Self.matchScore(track, observation, strict: !related) {
                    pairs.append((t, o, related ? score : score - 0.5))
                }
            }
        }
        for pair in pairs.sorted(by: { $0.score > $1.score })
        where !matchedTrack.contains(pair.track) && !matchedObservation.contains(pair.observation) {
            matchedTrack.insert(pair.track)
            matchedObservation.insert(pair.observation)
            observe(observations[pair.observation], into: &tracks[pair.track], now: now, pose: frame.pose)
        }

        for index in tracks.indices where !matchedTrack.contains(index) {
            tracks[index].hits.append(false)
        }
        for (index, observation) in observations.enumerated() where !matchedObservation.contains(index) {
            var track = TrackedObstacle(id: UUID(), label: observation.label, category: observation.category,
                                        boundingBox: observation.boundingBox, direction: observation.direction, lastSeen: now)
            track.hits = []
            observe(observation, into: &track, now: now, pose: frame.pose, isNew: true)
            tracks.append(track)
        }

        tracks = tracks.compactMap { track in
            var track = track
            track.hits = Array(track.hits.suffix(Self.window))
            if !track.isConfirmed && track.hits.filter({ $0 }).count >= Self.confirmHits { track.isConfirmed = true }
            if track.isConfirmed {
                guard now.timeIntervalSince(track.lastSeen) <= Self.keepAlive else { return nil }
            } else if !track.hits.suffix(3).contains(true) {
                return nil
            }
            // Out of view: things with a world position keep updating as the user moves.
            if let position = track.worldPosition, let pose = frame.pose {
                let relative = pose.relative(position)
                track.forward = relative.forward
                track.lateral = relative.lateral
            }
            Self.refresh(&track)
            return track
        }
        return tracks
    }

    // MARK: Matching

    /// Same name, the same kind of thing (Seat / Table, Step up / Stairs, Person / People), a name this
    /// track has been seen as before, or a plain "Obstacle" from depth (often the same thing YOLO names
    /// in another frame). Anything else must overlap closely to count as the same thing.
    private static func canMatch(_ track: TrackedObstacle, _ observation: DetectedObject) -> Bool {
        observation.label == track.label || observation.category == track.category || track.labelVotes[observation.label] != nil
            || observation.label == genericLabel || track.label == genericLabel
    }

    static let genericLabel = "Obstacle"

    private static func matchScore(_ track: TrackedObstacle, _ observation: DetectedObject, strict: Bool) -> Double? {
        let overlap = iou(track.boundingBox, observation.boundingBox)
        if overlap >= (strict ? 0.5 : 0.2) { return 1 + overlap }
        if let a = track.worldPosition, let b = observation.worldPosition {
            let gap = horizontalLength(a - b)
            return gap < (strict ? 0.4 : 0.8) ? 1 - gap : nil
        }
        if strict { return nil }
        // No world position (no LiDAR, or ground hazards): same thing at about the same distance and place.
        if let a = track.distance, let b = observation.distanceMeters,
           abs(a - b) < 0.8, abs(track.boundingBox.midX - observation.boundingBox.midX) < 0.15 {
            return 0.5
        }
        return nil
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let shared = intersection.width * intersection.height
        return Double(shared / (a.width * a.height + b.width * b.height - shared))
    }

    private static func horizontalLength(_ v: SIMD3<Double>) -> Double { (v.x * v.x + v.z * v.z).squareRoot() }

    // MARK: Updating

    private func observe(_ observation: DetectedObject, into track: inout TrackedObstacle, now: Date,
                         pose: WalkingPose?, isNew: Bool = false) {
        let dt = now.timeIntervalSince(track.lastSeen)
        let previousDistance = track.distance
        let previousWorld = track.worldPosition

        track.boundingBox = observation.boundingBox
        track.lastSeen = now
        // A real name beats the plain "Obstacle" from depth; otherwise the most common name wins.
        let vote = observation.label == Self.genericLabel ? 0 : 1
        track.labelVotes[observation.label, default: 0] += vote
        if let best = track.labelVotes.filter({ $0.value > 0 }).max(by: { $0.value < $1.value }) {
            if best.key != track.label, best.value > (track.labelVotes[track.label] ?? 0) {
                track.label = best.key
                track.category = observation.label == best.key ? observation.category : track.category
            }
        } else {
            track.label = observation.label
            track.category = observation.category
        }
        if observation.label == track.label { track.category = observation.category }
        track.hits.append(true)

        if let distance = observation.distanceMeters {
            let lateral = observation.lateralMeters
                ?? Double(observation.boundingBox.midX - 0.5) * 2 * Self.fallbackHalfFOVTangent * distance
            track.forward = distance
            track.lateral = lateral
        } else {
            track.forward = nil
            track.lateral = nil
        }

        if let position = observation.worldPosition {
            // Smooth the LiDAR position a little: box edges jitter from frame to frame.
            track.worldPosition = previousWorld.map { $0 + (position - $0) * 0.5 } ?? position
        }

        // Closing speed, smoothed.
        guard !isNew, dt > 0.01 else { return }
        var closing: Double?
        if let old = previousWorld, let new = track.worldPosition, let pose {
            // Its own movement toward the user, so the user walking up to a parked bike doesn't count.
            var velocity = (new - old) / dt
            velocity.y = 0
            var toUser = pose.origin - new
            toUser.y = 0
            let length = Self.horizontalLength(toUser)
            closing = length > 0.1 ? (velocity * toUser).sum() / length : 0
        } else if previousWorld == nil, let old = previousDistance, let new = track.distance {
            closing = (old - new) / dt
        }
        if let closing {
            track.closingSpeed += (closing - track.closingSpeed) * 0.35
        }
    }

    /// Recomputes direction, path, approach, and tier with hysteresis so labels don't flicker.
    private static func refresh(_ track: inout TrackedObstacle) {
        if let forward = track.forward, let lateral = track.lateral {
            let bearing = atan2(lateral, max(forward, 0.01)) * 180 / .pi
            track.direction = .stable(bearingDegrees: bearing, previous: track.direction)
            let halfWidth = track.inPath ? pathExit : pathEnter
            track.inPath = forward > 0.2 && abs(lateral) <= halfWidth
        } else {
            track.direction = RelativeDirection(normalizedX: track.boundingBox.midX)
            track.inPath = false
        }

        let movable = track.category == .person || track.category == .vehicle
        let threshold = track.worldPosition == nil ? approachSpeedEstimated : approachSpeedWorld
        // Start approaching above the threshold; stop when well below it.
        track.isApproaching = detectsApproaching && movable && track.closingSpeed > (track.isApproaching ? threshold * 0.6 : threshold)

        track.tier = tier(of: track)
    }

    static func tier(of track: TrackedObstacle) -> TrackedObstacle.Tier {
        guard track.isConfirmed, let distance = track.distance, let forward = track.forward, forward > 0 else { return .background }
        // Old sightings without a world position can't be updated, so they don't speak.
        if !track.isVisible && track.worldPosition == nil { return .background }

        if track.isApproaching && distance <= approachRange { return .urgent }
        guard track.inPath else { return .background }

        let isEdge = track.category == .dropOff || track.category == .stairs
        if distance <= stopRange || (isEdge && distance <= edgeStopRange) { return .urgent }
        return distance <= range(for: track.category) ? .important : .background
    }

    /// Cars, bikes, people, poles, and edges matter from farther away than a chair.
    static func range(for category: ObjectCategory) -> Double {
        switch category {
        case .vehicle, .person, .obstacle, .dropOff, .stairs: alertRange
        case .furniture, .sign: minorRange
        case .wall, .door: 0
        }
    }
}
