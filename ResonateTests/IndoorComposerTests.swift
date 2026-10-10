import CoreGraphics
import Foundation
import Testing
@testable import Resonate

/// The user stands at the origin facing world −Z, so "ahead" = −Z and "right" = +X.
private let pose = FloorPose(position: .zero, forward: SIMD2(0, -1))

/// World X/Z point from (meters ahead, meters to the right).
private func at(_ ahead: Double, _ right: Double) -> SIMD2<Double> { SIMD2(right, -ahead) }

private func object(_ label: String, ahead: Double, right: Double, size: Double = 0.4,
                    category: ObjectCategory = .furniture) -> RoomElement {
    let h = size / 2
    return RoomElement(kind: .object, label: label, category: category, footprint: [
        at(ahead - h, right - h), at(ahead - h, right + h), at(ahead + h, right + h), at(ahead + h, right - h),
    ])
}

private func wall(from a: (Double, Double), to b: (Double, Double)) -> RoomElement {
    RoomElement(kind: .wall, label: "Wall", category: .wall, footprint: [at(a.0, a.1), at(b.0, b.1)])
}

private func door(open: Bool, ahead: Double) -> RoomElement {
    RoomElement(kind: .door(isOpen: open), label: "Door", category: .door, footprint: [at(ahead, -0.45), at(ahead, 0.45)])
}

struct IndoorComposerTests {
    @Test func relativePositions() {
        let p = pose.relative(at(2, -1))
        #expect(abs(p.x - 2) < 1e-9)
        #expect(abs(p.y - -1) < 1e-9)
    }

    @Test func matchesTheDesignSentence() {
        let result = IndoorComposer.compose([object("Chair", ahead: 1.4, right: 0.6)], pose: pose)
        #expect(result.headline == "Chair 2 steps ahead, on your right.")
    }

    @Test func clearRoomWithAWallAlongsideAndAnOpenDoor() {
        let result = IndoorComposer.compose([
            wall(from: (-1, -0.8), to: (5, -0.8)),
            door(open: true, ahead: 5),
        ], pose: pose)
        #expect(result.headline == "The way ahead is clear.")
        #expect(result.guidance == "Walk straight. Wall stays on your left. Door is open ahead.")
        #expect(result.alert == nil)
    }

    @Test func closedDoorsAreNotOfferedAsAWayThrough() {
        let result = IndoorComposer.compose([door(open: false, ahead: 4)], pose: pose)
        #expect(!result.guidance.contains("Door"))
    }

    @Test func obstacleInThePathSaysWhichWayToStep() throws {
        // Chair slightly left of center, 1.2 m ahead: step right.
        let result = IndoorComposer.compose([object("Chair", ahead: 1.2, right: -0.15)], pose: pose)
        #expect(result.guidance.hasPrefix("Step right to pass."))
        let alert = try #require(result.alert)
        #expect(alert.severity == .headsUp)
    }

    @Test func veryCloseMeansStop() throws {
        let result = IndoorComposer.compose([object("Table", ahead: 0.6, right: 0)], pose: pose)
        #expect(result.guidance.hasPrefix("Stop."))
        let alert = try #require(result.alert)
        #expect(alert.severity == .stop)
        #expect(alert.headline == "Table right in front of you.")
    }

    @Test func stairsAlwaysStop() throws {
        let stairs = object("Stairs", ahead: 1.3, right: 0, size: 1, category: .stairs)
        let alert = try #require(IndoorComposer.compose([stairs], pose: pose).alert)
        #expect(alert.severity == .stop)
        #expect(alert.guidance.contains("railing"))
    }

    @Test func wallStraightAhead() {
        let result = IndoorComposer.compose([wall(from: (1.5, -3), to: (1.5, 3))], pose: pose)
        #expect(result.headline == "Wall 2 steps ahead.")
        #expect(result.guidance.hasPrefix("Wall ahead. Turn left or right."))
    }

    @Test func thingsBehindAreNotTheHeadline() {
        let result = IndoorComposer.compose([object("Chair", ahead: -1.5, right: 0)], pose: pose)
        #expect(result.headline == "The way ahead is clear.")
    }

    @Test func stepCountDoesNotChangeTheAnnouncementKey() {
        let far = IndoorComposer.compose([object("Chair", ahead: 2.5, right: 0.9)], pose: pose)
        let near = IndoorComposer.compose([object("Chair", ahead: 1.5, right: 0.6)], pose: pose)
        #expect(far.headline != near.headline)
        #expect(far.announcementKey == near.announcementKey)
    }

    @Test func miniMapPutsThingsAheadAboveTheUser() throws {
        let result = IndoorComposer.compose([object("Chair", ahead: 2, right: 1)], pose: pose)
        let item = try #require(result.miniMap.first)
        #expect(item.rect.midY < 0.81)  // ahead = up
        #expect(item.rect.midX > 0.5)   // right = right
    }
}
