import Foundation
import Testing
@testable import Resonate

/// A point `north` and `east` meters from a start near Georgia Tech.
private func point(north: Double, east: Double = 0) -> GeoPoint {
    let origin = GeoPoint(latitude: 33.7750, longitude: -84.3960)
    let metersPerDegreeLat = 111_195.0
    let metersPerDegreeLon = metersPerDegreeLat * cos(origin.latitude * .pi / 180)
    return GeoPoint(latitude: origin.latitude + north / metersPerDegreeLat, longitude: origin.longitude + east / metersPerDegreeLon)
}

private func fix(north: Double, east: Double = 0, accuracy: Double = 5, at seconds: TimeInterval = 0) -> LocationFix {
    LocationFix(point: point(north: north, east: east), accuracy: accuracy, timestamp: Date(timeIntervalSince1970: 1_000 + seconds))
}

/// Walk 100 m north, turn right, walk 50 m east, arrive.
private func sampleRoute(hazards: [RouteHazard] = []) -> Route {
    let destination = Place(id: "test", name: "Howey", address: "", coordinate: point(north: 100, east: 50))
    return Route(
        id: UUID(),
        destination: destination,
        durationSeconds: 120,
        distanceMeters: 150,
        isStepFree: true,
        features: [],
        steps: [
            RouteStep(id: 0, instruction: "Walk north", distanceMeters: 100, maneuver: .depart, start: point(north: 0)),
            RouteStep(id: 1, instruction: "Turn right onto Plum Street", distanceMeters: 50, maneuver: .right, start: point(north: 100),
                      spokenInstruction: "Turn right onto Plum Street. There's a curb ramp.", alertInstruction: "Turn right onto Plum Street."),
            RouteStep(id: 2, instruction: "Your destination is on the left", distanceMeters: 0, maneuver: .arrive, start: point(north: 100, east: 50)),
        ],
        polyline: [point(north: 0), point(north: 100), point(north: 100, east: 50)],
        avoided: [],
        hazards: hazards
    )
}

struct NavigationEngineTests {
    @Test func doesNotAnnounceATurnEightyMetersAwayAtStartup() {
        var engine = NavigationEngine(route: sampleRoute())
        #expect(engine.update(fix(north: 20, accuracy: 20)).isEmpty)
        let events = engine.update(fix(north: 80))
        guard case .approaching(let index, let distance)? = events.first else {
            Issue.record("Expected a warning only when the turn is close")
            return
        }
        #expect(index == 1)
        #expect(abs(distance - 20) < 1)
        #expect(engine.update(fix(north: 95)) == [.reached(stepIndex: 1)])
    }

    @Test func announcesTheTurnOnceWhenApproaching() {
        var engine = NavigationEngine(route: sampleRoute())
        #expect(engine.update(fix(north: 50)).isEmpty)

        let events = engine.update(fix(north: 80))
        #expect(events.count == 1)
        guard case .approaching(let index, let distance)? = events.first else {
            Issue.record("Expected an approaching event, got \(events)")
            return
        }
        #expect(index == 1)
        #expect(abs(distance - 20) < 1)
        #expect(engine.announcement(for: events[0]) == "In about 65 feet, turn right onto Plum Street.")

        // Not repeated on the next fix.
        #expect(engine.update(fix(north: 85)).isEmpty)
    }

    @Test func skipsTheEarlyWarningWhenTheTurnIsAlreadyClose() {
        var engine = NavigationEngine(route: sampleRoute())
        // First fix lands 12 m before the turn: no "In about 12 meters", just wait for the turn.
        #expect(engine.update(fix(north: 88)).isEmpty)
        #expect(engine.update(fix(north: 95)) == [.reached(stepIndex: 1)])
    }

    @Test func speaksTheFullInstructionAtTheTurn() {
        var engine = NavigationEngine(route: sampleRoute())
        let events = engine.update(fix(north: 95))
        #expect(events == [.reached(stepIndex: 1)])
        #expect(engine.stepIndex == 1)
        #expect(engine.announcement(for: events[0]) == "Turn right onto Plum Street. There's a curb ramp.")
    }

    @Test func arrivesNearTheDestinationAndThenStaysQuiet() {
        var engine = NavigationEngine(route: sampleRoute())
        _ = engine.update(fix(north: 100))
        let events = engine.update(fix(north: 100, east: 45))
        #expect(events == [.arrived])
        #expect(engine.hasArrived)
        #expect(engine.announcement(for: .arrived) == "You've arrived at Howey.")
        #expect(engine.update(fix(north: 100, east: 50)).isEmpty)
    }

    @Test func endsAtTheEntranceWhenThereIsOne() {
        var route = sampleRoute()
        let door = point(north: 100, east: 30)
        route.entrance = RouteEntrance(coordinate: door, isMain: true, door: "automatic")
        var engine = NavigationEngine(route: route)
        _ = engine.update(fix(north: 100))
        #expect(engine.update(fix(north: 100, east: 30)) == [.arrived])
        #expect(engine.announcement(for: .arrived) == "You've arrived at the main entrance of Howey. It has an automatic door.")
    }

    @Test func poorGPSDoesNotCountTheTurnEarly() {
        var engine = NavigationEngine(route: sampleRoute())
        // 18 m before the turn with 20 m accuracy: a heads-up with the distance, not "turn right" yet.
        let events = engine.update(fix(north: 82, accuracy: 20))
        #expect(events == [.approaching(stepIndex: 1, distance: 18)] || events.allSatisfy { if case .approaching = $0 { true } else { false } })
        #expect(engine.stepIndex == 0)
        #expect(engine.announcement(for: .approaching(stepIndex: 1, distance: 18)) == "In about 60 feet, turn right onto Plum Street.")
    }

    @Test func distanceToTheTurnCountsDown() {
        var engine = NavigationEngine(route: sampleRoute())
        var last = Double.infinity
        for north in stride(from: 5.0, through: 70, by: 5) {
            // GPS wobbles a few meters to the side.
            _ = engine.update(fix(north: north, east: north.truncatingRemainder(dividingBy: 10) == 0 ? 4 : -4))
            let remaining = engine.distanceToNextManeuver ?? .infinity
            #expect(remaining <= last)
            last = remaining
        }
        #expect(abs(last - 30) < 2)
    }

    @Test func aQuickSecondTurnIsNotAnnouncedDuringTheFirst() {
        // Right at 100 m north, then left only 20 m later.
        let destination = Place(id: "test", name: "Howey", address: "", coordinate: point(north: 150, east: 20))
        let route = Route(
            id: UUID(), destination: destination, durationSeconds: 120, distanceMeters: 170, isStepFree: true, features: [],
            steps: [
                RouteStep(id: 0, instruction: "Start walking", distanceMeters: 100, maneuver: .depart, start: point(north: 0)),
                RouteStep(id: 1, instruction: "Turn right onto Plum Street", distanceMeters: 20, maneuver: .right, start: point(north: 100)),
                RouteStep(id: 2, instruction: "Turn left onto Oak Street", distanceMeters: 50, maneuver: .left, start: point(north: 100, east: 20)),
                RouteStep(id: 3, instruction: "Arrive", distanceMeters: 0, maneuver: .arrive, start: point(north: 150, east: 20)),
            ],
            polyline: [point(north: 0), point(north: 100), point(north: 100, east: 20), point(north: 150, east: 20)],
            avoided: []
        )
        var engine = NavigationEngine(route: route)
        _ = engine.update(fix(north: 75, at: 0))
        #expect(engine.update(fix(north: 97, at: 8)) == [.reached(stepIndex: 1)])
        // Still turning right: no "turn left" yet.
        #expect(engine.update(fix(north: 100, east: 2, at: 10)).isEmpty)
        #expect(engine.nextStep?.instruction == "Turn left onto Oak Street")
        // The left turn is said at the left turn.
        #expect(engine.update(fix(north: 100, east: 16, at: 14)) == [.reached(stepIndex: 2)])
    }

    @Test func walkingBackwardSaysTurnAround() {
        var engine = NavigationEngine(route: sampleRoute())
        _ = engine.update(fix(north: 50, at: 0))
        // A little GPS wobble backward is fine.
        #expect(engine.update(fix(north: 45, at: 2)).isEmpty)
        // Walking back toward the start: it takes a few readings over several seconds to be sure.
        #expect(engine.update(fix(north: 35, at: 6)).isEmpty)
        #expect(engine.update(fix(north: 30, at: 9)) == [.wrongWay])
        #expect(engine.announcement(for: .wrongWay) == "Turn around. You're walking away from the route.")
        // Said once, not on every fix…
        #expect(engine.update(fix(north: 28, at: 11)).isEmpty)
        // …and the distance on screen doesn't count up meanwhile.
        #expect(abs((engine.distanceToNextManeuver ?? 0) - 50) < 2)
        _ = engine.update(fix(north: 40, at: 15))
        // Turned around.
        #expect(engine.update(fix(north: 46, at: 20)) == [.rightWay])
    }

    @Test func oneGPSJumpAheadIsNotWalkingTheWrongWay() {
        var engine = NavigationEngine(route: sampleRoute())
        _ = engine.update(fix(north: 20, at: 0))
        _ = engine.update(fix(north: 23, at: 2))
        // GPS spikes 40 m ahead, then settles back to where the user really is, walking forward.
        _ = engine.update(fix(north: 63, at: 4))
        for (i, north) in [26.0, 29, 32, 35, 38].enumerated() {
            #expect(!engine.update(fix(north: north, at: 6 + Double(i) * 2)).contains(.wrongWay))
        }
    }

    @Test func gpsDirectionOfTravelConfirmsTheWrongWay() {
        var engine = NavigationEngine(route: sampleRoute())
        _ = engine.update(fix(north: 50, at: 0))
        // GPS says walking north (the route's way) even though readings drift back: not the wrong way.
        for (i, north) in [44.0, 40, 36, 34].enumerated() {
            var reading = fix(north: north, at: 2 + Double(i) * 2)
            reading.course = 0
            reading.speed = 1.3
            #expect(!engine.update(reading).contains(.wrongWay))
        }
    }

    @Test func warnsBeforeArriving() {
        var engine = NavigationEngine(route: sampleRoute())
        _ = engine.update(fix(north: 100, at: 0))
        let events = engine.update(fix(north: 100, east: 30, at: 10))
        #expect(events == [.approaching(stepIndex: 2, distance: 20)] || events.contains { if case .approaching(2, _) = $0 { true } else { false } })
        #expect(engine.announcement(for: .approaching(stepIndex: 2, distance: 20)) == "In about 65 feet, you'll reach Howey.")
    }

    @Test func noTurnWarningsBeforeReachingTheRoute() {
        var engine = NavigationEngine(route: sampleRoute())
        // Still inside a building 25 m to the side of the route, level with the turn: nothing yet.
        #expect(engine.update(fix(north: 80, east: -25)).isEmpty)
        #expect(!engine.isOnPath)
        #expect(engine.distanceToNextManeuver == nil)
    }

    @Test func knowsWhenACrossingIsComing() {
        var route = sampleRoute()
        route.crossings = [point(north: 60)]
        var engine = NavigationEngine(route: route)
        _ = engine.update(fix(north: 10))
        #expect(!engine.isNearCrossing)
        _ = engine.update(fix(north: 45))
        #expect(engine.isNearCrossing)
        _ = engine.update(fix(north: 75))
        #expect(!engine.isNearCrossing)
    }

    @Test func oneBadGPSReadingDoesNotTriggerAReroute() {
        var engine = NavigationEngine(route: sampleRoute())
        #expect(engine.update(fix(north: 40, east: 60, at: 0)).isEmpty)
        #expect(engine.update(fix(north: 42, at: 2)).isEmpty)
        #expect(!engine.isOffRoute)
    }

    @Test func offRouteAfterStayingAwayThenBackOnRoute() {
        var engine = NavigationEngine(route: sampleRoute())
        #expect(engine.update(fix(north: 40, east: 60, at: 0)).isEmpty)
        #expect(engine.update(fix(north: 42, east: 62, at: 4)).isEmpty)
        #expect(engine.update(fix(north: 44, east: 64, at: 9)) == [.offRoute])
        // Announced once, not on every fix.
        #expect(engine.update(fix(north: 45, east: 65, at: 11)).isEmpty)
        #expect(engine.update(fix(north: 46, east: 2, at: 14)) == [.backOnRoute])
    }

    @Test func poorAccuracyWidensTheOffRouteThreshold() {
        var engine = NavigationEngine(route: sampleRoute())
        // 45 m off the line, but GPS says it could be 30 m off.
        _ = engine.update(fix(north: 40, east: 45, accuracy: 30, at: 0))
        #expect(engine.update(fix(north: 41, east: 45, accuracy: 30, at: 10)).isEmpty)
    }

    @Test func warnsAboutAHazardOnce() {
        let curb = RouteHazard(kind: .raisedCurb, coordinate: point(north: 60))
        var engine = NavigationEngine(route: sampleRoute(hazards: [curb]))
        #expect(engine.update(fix(north: 45)) == [.hazardAhead(curb)])
        #expect(engine.update(fix(north: 50)).isEmpty)
        #expect(engine.announcement(for: .hazardAhead(curb)) == "Raised curb ahead. Watch the edge.")
    }
}

@MainActor
struct WalkStartupTests {
    final class HeldSpeech: SpeechServicing {
        var isSpeaking = false
        var lastSpoken: String?
        private var completion: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { completion != nil }
        func speak(_ text: String, priority: SpeechPriority, fragments: [String]?) async {
            isSpeaking = true
            lastSpoken = text
        }
        func waitUntilFinished() async {
            await withCheckedContinuation { completion = $0 }
        }
        func finish() {
            isSpeaking = false
            let saved = completion
            completion = nil
            saved?.resume()
        }
        func stop() { lastSpoken = nil; finish() }
        func repeatLast() async {}
        func prewarm(_ phrases: [String]) async {}
    }

    @Test func scanningWaitsUntilTheStartupSpeechFinishes() async throws {
        let services = AppServices.mock()
        let speech = HeldSpeech()
        let feedback = FeedbackCenter(speech: speech, haptics: services.haptics,
                                      tones: services.tones, preferences: UserPreferences())
        let model = WalkViewModel(mode: .navigating(sampleRoute()), services: services, feedback: feedback)
        let task = Task { await model.run() }
        defer { task.cancel(); speech.stop() }
        let deadline = Date().addingTimeInterval(2)
        while !speech.isWaiting, Date() < deadline { await Task.yield() }
        #expect(speech.isWaiting)
        #expect(model.isStarting)
        #expect(model.objects.isEmpty)
        #expect(model.currentLocation == nil)
        speech.finish()
        let startedDeadline = Date().addingTimeInterval(2)
        while model.currentLocation == nil, Date() < startedDeadline { await Task.yield() }
        #expect(!model.isStarting)
        #expect(model.currentLocation != nil)
        task.cancel()
        await task.value
    }

    @Test func closingDuringStartupNeverStartsScanning() async {
        let services = AppServices.mock()
        let speech = HeldSpeech()
        let feedback = FeedbackCenter(speech: speech, haptics: services.haptics,
                                      tones: services.tones, preferences: UserPreferences())
        let model = WalkViewModel(mode: .navigating(sampleRoute()), services: services, feedback: feedback)
        let task = Task { await model.run() }
        let deadline = Date().addingTimeInterval(2)
        while !speech.isWaiting, Date() < deadline { await Task.yield() }
        #expect(speech.isWaiting)
        feedback.endScreenSpeech()
        await task.value
        #expect(model.objects.isEmpty)
        #expect(model.currentLocation == nil)
    }

    @Test func startsWithBeginningRouteAndScanningInsteadOfRepeatingRouteDetails() async throws {
        let services = AppServices.mock()
        let app = AppModel(services: services)
        let location = try #require(services.location as? MockLocationService)
        location.location = point(north: 20)
        let speech = try #require(services.speech as? MockSpeechService)
        var route = sampleRoute()
        route.features = [.curbRamps, .audioCrossings, .unverifiedSegments]
        route.steps[0].spokenInstruction = "Walk north. Then turn right."
        let model = WalkViewModel(mode: .navigating(route), services: services, feedback: app.feedback)
        let task = Task { await model.run() }
        while model.currentLocation == nil { await Task.yield() }
        task.cancel()
        await task.value
        let announcements = speech.log.filter { $0.priority == .navigation }.map(\.text)
        #expect(announcements.count == 1)
        let message = try #require(announcements.first)
        #expect(message.hasPrefix("Beginning route. "))
        #expect(!message.contains("2 minutes"))
        #expect(!message.contains("Curb ramps"))
        #expect(message.contains("Beginning to scan the area. Point the phone in front of you."))
        #expect(!message.lowercased().contains("turn right"))
        #expect(model.navigation?.stepIndex == 0)
    }
}

struct GeometryTests {
    @Test func distanceFromRouteLine() {
        let route = sampleRoute()
        #expect(abs(route.distanceFromPath(point(north: 50, east: 10)) - 10) < 0.5)
        #expect(route.distanceFromPath(point(north: 100, east: 25)) < 0.5)
    }

    @Test func georgiaBoundingBox() {
        #expect(GeorgiaRegion.contains(GeoPoint(latitude: 33.7756, longitude: -84.3963)))   // Atlanta
        #expect(!GeorgiaRegion.contains(GeoPoint(latitude: 35.0456, longitude: -85.3097)))  // Chattanooga, TN
        #expect(!GeorgiaRegion.contains(GeoPoint(latitude: 41.7151, longitude: 44.8271)))   // Tbilisi, country of Georgia
    }

    @Test func spokenAndShortDistances() {
        #expect(DistanceText.short(2.4) == "8 ft")
        #expect(DistanceText.short(42) == "140 ft")
        #expect(DistanceText.spoken(0.3) == "1 foot")
        #expect(DistanceText.spoken(3) == "10 feet")
        #expect(DistanceText.spoken(1450) == "0.9 miles")
        #expect(DistanceText.spoken(1609) == "1 mile")
    }
}

struct RouteWordingTests {
    @Test func dropsCompassDirections() {
        #expect(RouteWording.relative("Walk northeast on Peachtree Street.") == "Walk on Peachtree Street.")
        #expect(RouteWording.relative("Head south for 200 meters.") == "Head for 200 meters.")
        #expect(RouteWording.relative("Walk west.") == "Start walking.")
        #expect(RouteWording.relative("Turn right onto A Street. Then, in 200 feet, Turn left onto B Street.") == "Turn right onto A Street.")
    }

    @Test func keepsStreetNames() {
        #expect(RouteWording.relative("Continue east on North Avenue.") == "Continue on North Avenue.")
        #expect(RouteWording.relative("Turn left onto East Paces Ferry Road.") == "Turn left onto East Paces Ferry Road.")
    }

    @Test func saysWhichWayToFaceAtTheStart() {
        #expect(RouteWording.orientation(heading: 0, routeBearing: 10) == nil)
        #expect(RouteWording.orientation(heading: 0, routeBearing: 45) == "Turn slightly right.")
        #expect(RouteWording.orientation(heading: 10, routeBearing: 280) == "Turn left.")
        #expect(RouteWording.orientation(heading: 90, routeBearing: 260) == "Turn around.")
    }
}
