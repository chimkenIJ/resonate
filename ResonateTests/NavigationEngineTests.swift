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
        #expect(engine.announcement(for: events[0]) == "In about 20 meters, turn right onto Plum Street.")

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
        #expect(engine.announcement(for: .hazardAhead(curb)) == "Raised curb ahead. Check the edge with your cane.")
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
        #expect(DistanceText.short(2.4) == "2 m")
        #expect(DistanceText.short(42) == "40 m")
        #expect(DistanceText.spoken(1) == "1 meter")
        #expect(DistanceText.spoken(1450) == "1.5 kilometers")
    }
}
