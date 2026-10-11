import Foundation
import Testing
import simd
@testable import Resonate

/// The user stands at the origin facing world −Z: "ahead" = −Z, "right" = +X.
private let facingAhead = FloorPose(position: .zero, forward: SIMD2(0, -1))
private func at(_ ahead: Double, _ right: Double) -> SIMD2<Double> { SIMD2(right, -ahead) }

private func box(_ label: String = "Obstacle", ahead: Double, right: Double, size: Double = 0.5,
                 category: ObjectCategory = .obstacle, id: UUID = UUID()) -> RoomElement {
    let h = size / 2
    return RoomElement(kind: .object, label: label, category: category, footprint: [
        at(ahead - h, right - h), at(ahead - h, right + h), at(ahead + h, right + h), at(ahead + h, right - h),
    ], id: id)
}

private func wall(from a: (Double, Double), to b: (Double, Double)) -> RoomElement {
    RoomElement(kind: .wall, label: "Wall", category: .wall, footprint: [at(a.0, a.1), at(b.0, b.1)])
}

private let start = Date(timeIntervalSince1970: 0)

struct IndoorMapTests {
    @Test func remembersWhatTheCameraFoundAfterItLooksAway() {
        var map = IndoorMap()
        let bin = box("Bin", ahead: 2, right: 0)
        map.update([bin], live: [bin.id], pose: facingAhead, now: start)
        // Turned around: the bin is out of view and no longer reported.
        let facingBack = FloorPose(position: .zero, forward: SIMD2(0, 1))
        map.update([], live: [], pose: facingBack, now: start.addingTimeInterval(60))
        #expect(map.elements.map(\.id) == [bin.id])
        // Three minutes on, it's forgotten.
        map.update([], live: [], pose: facingBack, now: start.addingTimeInterval(181))
        #expect(map.elements.isEmpty)
    }

    @Test func theSameThingFoundAgainIsOneThing() {
        var map = IndoorMap()
        let first = box(ahead: 2, right: 0)
        map.update([first], live: [first.id], pose: facingAhead, now: start)
        let again = box(ahead: 2.2, right: 0.1) // a new camera track of the same thing
        map.update([again], live: [again.id], pose: facingAhead, now: start.addingTimeInterval(1))
        #expect(map.elements.count == 1)
        #expect(map.elements.first?.id == first.id)
    }

    @Test func forgetsWhatIsntThereWhenLookingRightAtIt() {
        var map = IndoorMap()
        let chair = box("Chair", ahead: 2, right: 0, category: .furniture)
        map.update([chair], live: [chair.id], pose: facingAhead, now: start)
        // Still looking at that spot, and it's gone (moved).
        map.update([], live: [], pose: facingAhead, now: start.addingTimeInterval(2))
        #expect(map.elements.isEmpty)
    }

    @Test func peopleAreOnlyRememberedBriefly() {
        var map = IndoorMap()
        let person = box("Person", ahead: 2, right: 0, category: .person)
        map.update([person], live: [person.id], pose: facingAhead, now: start)
        let facingBack = FloorPose(position: .zero, forward: SIMD2(0, 1))
        map.update([], live: [], pose: facingBack, now: start.addingTimeInterval(5))
        #expect(map.elements.isEmpty)
    }

    @Test func theRoomScanIsKeptAsReported() {
        var map = IndoorMap()
        let side = wall(from: (-1, 2), to: (5, 2))
        map.update([side], live: [], pose: facingAhead, now: start)
        #expect(map.elements.map(\.id) == [side.id])
    }

    @Test func headingIsTheWayTheyreWalking() {
        var map = IndoorMap()
        // Phone faces ahead (−Z) but the user walks to the right (+X).
        for i in 0...5 {
            let pose = FloorPose(position: SIMD2(Double(i) * 0.15, 0), forward: SIMD2(0, -1))
            map.update([], live: [], pose: pose, now: start.addingTimeInterval(Double(i) * 0.25))
        }
        let heading = map.heading(FloorPose(position: SIMD2(0.75, 0), forward: SIMD2(0, -1)))
        #expect(abs(heading.forward.x - 1) < 0.01)
    }

    @Test func standingStillTheHeadingIsWhereThePhoneFaces() {
        var map = IndoorMap()
        let pose = FloorPose(position: .zero, forward: SIMD2(0, -1))
        map.update([], live: [], pose: pose, now: start)
        map.update([], live: [], pose: pose, now: start.addingTimeInterval(1))
        #expect(map.heading(pose).forward == pose.forward)
    }

    @Test func turningInACircleFillsTheCoverage() {
        var map = IndoorMap()
        for step in 0..<12 {
            let angle = (Double(step) + 0.5) * .pi / 6
            map.update([], live: [], pose: FloorPose(position: .zero, forward: SIMD2(cos(angle), sin(angle))), now: start)
        }
        #expect(map.coverage == 1)
    }
}

@MainActor
struct IndoorMappingTests {
    @Test func nothingAboutObstaclesWhileMapping() async throws {
        let app = AppModel(services: .mock())
        let speech = try #require(app.services.speech as? MockSpeechService)
        let model = IndoorScanViewModel(services: app.services, feedback: app.feedback)
        let task = Task { await model.run() }
        try await Task.sleep(for: .seconds(1))
        task.cancel()
        #expect(model.isMapping)
        #expect(model.overlayObjects.isEmpty)
        #expect(model.headline == "Mapping the room.")
        #expect(speech.log.map(\.text).allSatisfy { $0.hasPrefix("Indoors.") })
        #expect(!speech.log.contains { $0.priority == .safety })
    }
}
