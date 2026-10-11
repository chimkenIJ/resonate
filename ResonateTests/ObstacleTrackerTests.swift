import CoreGraphics
import Foundation
import Testing
@testable import Resonate

private func object(_ label: String, _ category: ObjectCategory, x: CGFloat, distance: Double?,
                    lateral: Double? = nil, world: SIMD3<Double>? = nil) -> DetectedObject {
    DetectedObject(label: label, category: category, confidence: 0.9,
                   boundingBox: CGRect(x: x - 0.05, y: 0.4, width: 0.1, height: 0.2),
                   distanceMeters: distance, lateralMeters: lateral, worldPosition: world)
}

private let start = Date(timeIntervalSince1970: 0)

/// Runs the same objects through the tracker for `count` frames, 0.1 s apart.
private func run(_ tracker: inout ObstacleTracker, _ objects: [DetectedObject], frames count: Int,
                 from: Date = start, pose: WalkingPose? = nil) -> [TrackedObstacle] {
    var tracks: [TrackedObstacle] = []
    for i in 0..<count {
        tracks = tracker.update(with: DetectionFrame(objects: objects, depthSource: .lidar, pose: pose),
                                now: from.addingTimeInterval(Double(i) * 0.1))
    }
    return tracks
}

struct ObstacleTrackerTests {
    @Test func needsThreeSightingsBeforeItCounts() {
        var tracker = ObstacleTracker()
        let pole = object("Fire hydrant", .obstacle, x: 0.5, distance: 2, lateral: 0)
        #expect(run(&tracker, [pole], frames: 2).first?.isConfirmed == false)
        #expect(run(&tracker, [pole], frames: 1, from: start.addingTimeInterval(0.2)).first?.isConfirmed == true)
    }

    @Test func keepsOneIdentityAsItMoves() {
        var tracker = ObstacleTracker()
        var ids = Set<UUID>()
        for i in 0..<10 {
            let person = object("Person", .person, x: 0.4 + CGFloat(i) * 0.01, distance: 3 - Double(i) * 0.05, lateral: 0)
            let tracks = tracker.update(with: DetectionFrame(objects: [person], depthSource: .lidar),
                                        now: start.addingTimeInterval(Double(i) * 0.1))
            ids.formUnion(tracks.map(\.id))
        }
        #expect(ids.count == 1)
    }

    @Test func oneFrameFlickerIsDropped() {
        var tracker = ObstacleTracker()
        _ = run(&tracker, [object("Dog", .obstacle, x: 0.5, distance: 2, lateral: 0)], frames: 1)
        let tracks = run(&tracker, [], frames: 3, from: start.addingTimeInterval(0.1))
        #expect(tracks.isEmpty)
    }

    @Test func benchAtTheSideStaysSilent() {
        var tracker = ObstacleTracker()
        let bench = object("Bench", .furniture, x: 0.9, distance: 2, lateral: 1.5)
        #expect(run(&tracker, [bench], frames: 5).first?.tier == .background)
    }

    @Test func poleInThePathIsImportantThenUrgent() {
        var tracker = ObstacleTracker()
        #expect(run(&tracker, [object("Parking meter", .obstacle, x: 0.5, distance: 3, lateral: 0.2)], frames: 5).first?.tier == .important)
        let close = run(&tracker, [object("Parking meter", .obstacle, x: 0.5, distance: 1.2, lateral: 0.2)],
                        frames: 1, from: start.addingTimeInterval(0.5))
        #expect(close.first?.tier == .urgent)
    }

    @Test func chairOnlyMattersUpClose() {
        var tracker = ObstacleTracker()
        #expect(run(&tracker, [object("Chair", .furniture, x: 0.5, distance: 3.5, lateral: 0)], frames: 5).first?.tier == .background)
    }

    @Test(.enabled(if: ObstacleTracker.detectsApproaching)) func bikeComingFromTheSideIsUrgent() {
        var tracker = ObstacleTracker()
        let pose = WalkingPose(origin: .zero, forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))
        var tracks: [TrackedObstacle] = []
        // A bike 4 m ahead and 3 m to the right, riding toward the user at 3 m/s.
        for i in 0..<10 {
            let t = Double(i) * 0.1
            let position = SIMD3<Double>(3 - 2.1 * t, 0, -4 + 2.1 * t)
            tracks = tracker.update(with: DetectionFrame(objects: [object("Bike", .vehicle, x: 0.9, distance: 5, world: position)],
                                                         depthSource: .lidar, pose: pose),
                                    now: start.addingTimeInterval(t))
        }
        let bike = tracks.first
        #expect(bike?.isApproaching == true)
        #expect(bike?.tier == .urgent)
        #expect(bike?.approachSide == .right)
    }

    @Test func parkedBikeTheUserWalksTowardIsNotApproaching() {
        var tracker = ObstacleTracker()
        var tracks: [TrackedObstacle] = []
        for i in 0..<10 {
            let t = Double(i) * 0.1
            let pose = WalkingPose(origin: SIMD3(0, 0, -1.4 * t), forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))
            tracks = tracker.update(with: DetectionFrame(objects: [object("Bike", .vehicle, x: 0.5, distance: 4 - 1.4 * t, world: SIMD3(0, 0, -4))],
                                                         depthSource: .lidar, pose: pose),
                                    now: start.addingTimeInterval(t))
        }
        #expect(tracks.first?.isApproaching == false)
    }

    @Test func remembersThingsJustOutOfView() {
        var tracker = ObstacleTracker()
        let pose = WalkingPose(origin: .zero, forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))
        _ = run(&tracker, [object("Fire hydrant", .obstacle, x: 0.5, distance: 2, world: SIMD3(0.3, 0, -2))], frames: 5, pose: pose)
        // The user turns away; it's still there, now on their left.
        let turned = WalkingPose(origin: .zero, forward: SIMD3(1, 0, 0), right: SIMD3(0, 0, 1))
        let tracks = run(&tracker, [], frames: 5, from: start.addingTimeInterval(0.5), pose: turned)
        #expect(tracks.first?.direction == .left)
        // …and forgotten a few seconds later.
        #expect(run(&tracker, [], frames: 1, from: start.addingTimeInterval(5), pose: turned).isEmpty)
    }

    @Test func keepsOneNameWhenTheGuessFlips() {
        var tracker = ObstacleTracker()
        var tracks: [TrackedObstacle] = []
        let labels = ["Seat", "Seat", "Table", "Seat", "Obstacle", "Table", "Seat"]
        for (i, label) in labels.enumerated() {
            tracks = tracker.update(with: DetectionFrame(objects: [object(label, .furniture, x: 0.5, distance: 2, lateral: 0)],
                                                         depthSource: .lidar),
                                    now: start.addingTimeInterval(Double(i) * 0.1))
            #expect(tracks.count == 1)
            #expect(tracks.first?.label == "Seat")
        }
    }

    @Test func outsideAnythingThatStaysPutIsJustAnObstacle() {
        var tracker = ObstacleTracker()
        var tracks: [TrackedObstacle] = []
        // The detector can't decide what this bollard is.
        let guesses: [(String, ObjectCategory)] = [("Post", .obstacle), ("Toilet", .furniture), ("Seat", .furniture),
                                                   ("Post", .obstacle), ("Planter", .obstacle), ("Toilet", .furniture)]
        for (i, guess) in guesses.enumerated() {
            let seen = ObjectCatalog.forWalking(object(guess.0, guess.1, x: 0.5, distance: 2, lateral: 0))
            tracks = tracker.update(with: DetectionFrame(objects: [seen], depthSource: .lidar), now: start.addingTimeInterval(Double(i) * 0.1))
            #expect(tracks.count == 1)
            #expect(tracks.first?.label == "Obstacle")
        }
        #expect(tracks.first?.tier == .important)
    }

    @Test func thingsThatMoveKeepTheirNames() {
        for (label, category) in [("Person", ObjectCategory.person), ("People", .person), ("Cyclist", .vehicle),
                                  ("Vehicle", .vehicle), ("Animal", .obstacle), ("Stairs going up", .stairs), ("Curb drop", .dropOff)] {
            #expect(ObjectCatalog.forWalking(object(label, category, x: 0.5, distance: 2)).label == label)
        }
    }

    @Test func aDepthObstacleTakesARealNameOnlyOnceItsSeenMoreOften() {
        var tracker = ObstacleTracker()
        _ = run(&tracker, [object("Obstacle", .obstacle, x: 0.5, distance: 2, lateral: 0)], frames: 3)
        // One "car" guess doesn't rename it…
        var tracks = run(&tracker, [object("Vehicle", .vehicle, x: 0.5, distance: 1.9, lateral: 0)], frames: 1, from: start.addingTimeInterval(0.3))
        #expect(tracks.count == 1)
        #expect(tracks.first?.label == "Obstacle")
        // …but a person seen again and again does.
        tracks = run(&tracker, [object("Person", .person, x: 0.5, distance: 1.9, lateral: 0)], frames: 4, from: start.addingTimeInterval(0.4))
        #expect(tracks.count == 1)
        #expect(tracks.first?.label == "Person")
    }

    @Test func stairsAndAPostAreNeverMerged() {
        var tracker = ObstacleTracker()
        let stairs = DetectedObject(label: "Stairs going up", category: .stairs, confidence: 1,
                                    boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.16), distanceMeters: 2, lateralMeters: 0)
        let post = object("Obstacle", .obstacle, x: 0.5, distance: 2, lateral: 0)
        let tracks = run(&tracker, [stairs, post], frames: 5)
        #expect(Set(tracks.map(\.label)) == ["Stairs going up", "Obstacle"])
    }

    @Test func directionDoesNotFlipOnTheBoundary() {
        #expect(RelativeDirection.stable(bearingDegrees: 11, previous: .ahead) == .ahead)
        #expect(RelativeDirection.stable(bearingDegrees: 16, previous: .ahead) == .slightlyRight)
    }
}

struct WalkNarratorTests {
    private func track(_ label: String, _ category: ObjectCategory, distance: Double, lateral: Double = 0,
                       tier: TrackedObstacle.Tier) -> TrackedObstacle {
        var track = TrackedObstacle(id: UUID(), label: label, category: category,
                                    boundingBox: CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2),
                                    direction: RelativeDirection(bearingDegrees: atan2(lateral, distance) * 180 / .pi), lastSeen: start)
        track.forward = distance
        track.lateral = lateral
        track.isConfirmed = true
        track.inPath = abs(lateral) <= 0.6
        track.tier = tier
        return track
    }

    private func summaries(_ outputs: [WalkNarrator.Output]) -> [(ObstacleAlert, Bool)] {
        outputs.compactMap { if case .summary(let alert, let speak, _, _) = $0 { (alert, speak) } else { nil } }
    }

    @Test func reportsAfterLookingForTwoSeconds() {
        var narrator = WalkNarrator()
        let person = track("Person", .person, distance: 2, lateral: 0.7, tier: .important)
        #expect(summaries(narrator.update(tracks: [person], clearance: nil, canSpeak: true, now: start)).isEmpty)
        #expect(summaries(narrator.update(tracks: [person], clearance: nil, canSpeak: true, now: start.addingTimeInterval(1))).isEmpty)
        let spoken = summaries(narrator.update(tracks: [person], clearance: nil, canSpeak: true, now: start.addingTimeInterval(2)))
        #expect(spoken.count == 1)
        #expect(spoken.first?.1 == true)
        #expect(spoken.first?.0.spokenText == "Path clear. Person ahead, slightly right, 7 feet.")
    }

    @Test func doesNotRepeatAnUnchangedSummary() {
        var narrator = WalkNarrator()
        let person = track("Person", .person, distance: 3, lateral: 0.3, tier: .important)
        _ = narrator.update(tracks: [person], clearance: nil, canSpeak: true, now: start)
        #expect(summaries(narrator.update(tracks: [person], clearance: nil, canSpeak: true, now: start.addingTimeInterval(5))).first?.1 == true)
        #expect(summaries(narrator.update(tracks: [person], clearance: nil, canSpeak: true, now: start.addingTimeInterval(10))).first?.1 == false)
    }

    @Test func neverTalksOverOtherSpeech() {
        var narrator = WalkNarrator()
        let person = track("Person", .person, distance: 3, tier: .important)
        _ = narrator.update(tracks: [person], clearance: nil, canSpeak: false, now: start)
        #expect(summaries(narrator.update(tracks: [person], clearance: nil, canSpeak: false, now: start.addingTimeInterval(5))).first?.1 == false)
        // Said once it's quiet.
        #expect(summaries(narrator.update(tracks: [person], clearance: nil, canSpeak: true, now: start.addingTimeInterval(10))).first?.1 == true)
    }

    @Test func urgentInterruptsOnceRightAway() {
        var narrator = WalkNarrator()
        let pole = track("Parking meter", .obstacle, distance: 1.2, tier: .urgent)
        let first = narrator.update(tracks: [pole], clearance: nil, canSpeak: false, now: start)
        guard case .urgent(let alert) = first.first else { Issue.record("Expected an urgent alert"); return }
        #expect(alert.spokenText == "Stop. Veer left. Parking meter straight ahead.")
        #expect(alert.guidance == "Veer left.")
        let again = narrator.update(tracks: [pole], clearance: nil, canSpeak: true, now: start.addingTimeInterval(1))
        #expect(!again.contains { if case .urgent = $0 { true } else { false } })
    }

    @Test func aSwingingPhoneDoesntRepeatTheWarning() {
        var narrator = WalkNarrator()
        let pole = track("Post", .obstacle, distance: 1.2, tier: .urgent)
        #expect(narrator.update(tracks: [pole], clearance: nil, canSpeak: true, now: start).contains { if case .urgent = $0 { true } else { false } })
        // The camera loses it and finds it again as a new thing, over and over.
        for i in 1...12 {
            let refound = track(i.isMultiple(of: 2) ? "Post" : "Obstacle", .obstacle, distance: 1.2, tier: .urgent)
            let outputs = narrator.update(tracks: [refound], clearance: nil, canSpeak: true, now: start.addingTimeInterval(Double(i) * 0.5))
            #expect(!outputs.contains { if case .urgent = $0 { true } else { false } })
        }
        // A different kind of danger is still said right away.
        let edge = track("Drop-off", .dropOff, distance: 1.5, tier: .urgent)
        #expect(narrator.update(tracks: [edge], clearance: nil, canSpeak: true, now: start.addingTimeInterval(6.5)).contains { if case .urgent = $0 { true } else { false } })
    }

    @Test func warningSaysWhatToDoThenWhatsAround() {
        var narrator = WalkNarrator()
        let person = track("Person", .person, distance: 2, lateral: 1.5, tier: .important)
        _ = narrator.update(tracks: [person], clearance: nil, canSpeak: true, now: start)
        let pole = track("Parking meter", .obstacle, distance: 1.2, tier: .urgent)
        let outputs = narrator.update(tracks: [pole, person], clearance: nil, canSpeak: true, now: start.addingTimeInterval(0.5))
        guard case .urgent(let alert)? = outputs.first else { Issue.record("Expected an urgent alert"); return }
        #expect(alert.spokenText == "Stop. Veer left. Parking meter straight ahead. Person on your right, 8 feet.")
    }

    @Test func approachingSaysWhereFrom() {
        var car = track("Vehicle", .vehicle, distance: 5, lateral: 2, tier: .urgent)
        car.isApproaching = true
        #expect(WalkNarrator.urgentAlert(for: car).spokenText == "Stop. Vehicle approaching from the right. Wait for it to pass.")
    }

    @Test func stopSaysWhichWayHasRoom() {
        let post = track("Post", .obstacle, distance: 1.2, lateral: -0.2, tier: .urgent)
        // Away from it with no depth info…
        #expect(WalkNarrator.urgentAlert(for: post).guidance == "Veer right.")
        // …but toward the side LiDAR says is open.
        #expect(WalkNarrator.urgentAlert(for: post, clearance: PathClearance(left: nil, center: 1.2, right: 1.0)).guidance == "Veer left.")
        #expect(WalkNarrator.urgentAlert(for: post, clearance: PathClearance(left: 1.1, center: 1.2, right: 1.0)).guidance == "Turn left or right.")
    }

    @Test func buzzesOnlyWhenTheNearestThingGetsCloser() {
        var narrator = WalkNarrator()
        func pulses(_ distance: Double, at seconds: Double) -> Int {
            narrator.update(tracks: [track("Bench", .furniture, distance: distance, tier: .important)],
                            clearance: nil, canSpeak: true, now: start.addingTimeInterval(seconds))
                .filter { $0 == .pulse }.count
        }
        #expect(pulses(2.4, at: 0) == 1)
        #expect(pulses(2.4, at: 0.1) == 0)
        #expect(pulses(2.3, at: 5) == 0)
        #expect(pulses(1.9, at: 6) == 1)
    }

    @Test func staysQuietWhileClimbingStairs() {
        var narrator = WalkNarrator()
        var stairs = track("Stairs going up", .stairs, distance: 1.5, tier: .urgent)
        stairs.hits = [true]
        #expect(narrator.update(tracks: [stairs], clearance: nil, canSpeak: true, now: start).contains { if case .urgent = $0 { true } else { false } })
        #expect(narrator.isOnStairs)
        // The phone tilts: the steps come back as new things over and over. None of it is said.
        for i in 1...20 {
            var again = track(i.isMultiple(of: 2) ? TerrainAnalyzer.stairsUpLabel : "Obstacle", i.isMultiple(of: 2) ? .stairs : .obstacle, distance: 1, tier: .urgent)
            again.hits = [true]
            let outputs = narrator.update(tracks: [again, stairs], clearance: nil, canSpeak: true, now: start.addingTimeInterval(Double(i) * 0.5))
            #expect(!outputs.contains { if case .urgent = $0 { true } else { false } })
            #expect(!outputs.contains { $0 == .pulse })
        }
        // Off the stairs for a while: back to normal.
        _ = narrator.update(tracks: [], clearance: nil, canSpeak: true, now: start.addingTimeInterval(30))
        #expect(!narrator.isOnStairs)
    }

    @Test func pathAdvicePicksTheSideWithRoom() {
        #expect(WalkNarrator.advice(clearance: PathClearance(left: nil, center: 2, right: 1.5), inPath: [], previous: .clear) == .veerLeft)
        #expect(WalkNarrator.advice(clearance: PathClearance(left: 1.8, center: 2, right: 2.2), inPath: [], previous: .clear) == .blocked)
        #expect(WalkNarrator.advice(clearance: PathClearance(left: nil, center: nil, right: nil), inPath: [], previous: .blocked) == .clear)
        // Hysteresis: once clear, it stays clear until something is clearly closer.
        #expect(WalkNarrator.advice(clearance: PathClearance(center: 2.8), inPath: [], previous: .clear) == .clear)
        #expect(WalkNarrator.advice(clearance: PathClearance(center: 2.8), inPath: [], previous: .blocked) == .veerLeft)
    }
}
