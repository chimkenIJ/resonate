import CoreGraphics
import Foundation
import Testing
@testable import Resonate

/// The user stands at the origin facing world −Z, so "ahead" = −Z and "right" = +X.
private let pose = FloorPose(position: .zero, forward: SIMD2(0, -1))

/// World X/Z point from (meters ahead, meters to the right).
private func at(_ ahead: Double, _ right: Double) -> SIMD2<Double> { SIMD2(right, -ahead) }

private func object(_ label: String, ahead: Double, right: Double, size: Double = 0.4,
                    category: ObjectCategory = .furniture, id: UUID = UUID()) -> RoomElement {
    let h = size / 2
    return RoomElement(kind: .object, label: label, category: category, footprint: [
        at(ahead - h, right - h), at(ahead - h, right + h), at(ahead + h, right + h), at(ahead + h, right - h),
    ], id: id)
}

private func wall(from a: (Double, Double), to b: (Double, Double)) -> RoomElement {
    RoomElement(kind: .wall, label: "Wall", category: .wall, footprint: [at(a.0, a.1), at(b.0, b.1)])
}

private func door(open: Bool, ahead: Double, right: Double = 0, id: UUID = UUID()) -> RoomElement {
    RoomElement(kind: .door(isOpen: open), label: "Door", category: .door,
                footprint: [at(ahead, right - 0.45), at(ahead, right + 0.45)], id: id)
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

    @Test func aClearRoomPointsOutTheDoor() {
        let result = IndoorComposer.compose([
            wall(from: (-1, -0.8), to: (5, -0.8)),
            door(open: true, ahead: 5),
        ], pose: pose)
        #expect(result.headline == "Door 7 steps straight ahead.")
        #expect(result.guidance == "Walk straight. Wall stays on your left.")
        #expect(result.summary.joined(separator: " ") == "Door 7 steps straight ahead.")
        #expect(result.alert == nil)
    }

    @Test func saysWhenTheDoorAheadIsClosed() {
        let result = IndoorComposer.compose([door(open: false, ahead: 4)], pose: pose)
        #expect(result.summary.joined(separator: " ") == "Door 6 steps straight ahead. It's closed.")
    }

    @Test func prefersAnOpenDoorToACloserClosedOne() {
        let open = door(open: true, ahead: 5, right: 2)
        let result = IndoorComposer.compose([door(open: false, ahead: 3, right: -2), open], pose: pose)
        #expect(result.doors.first?.element.id == open.id)
    }

    @Test func clearWhenNothingIsAround() {
        let result = IndoorComposer.compose([], pose: pose)
        #expect(result.headline == "The way ahead is clear.")
        #expect(result.summary == ["Clear ahead."])
    }

    @Test func obstacleInThePathSaysWhichWayToStepWithoutStopping() {
        // Chair slightly left of center, 1.2 m ahead: step right, but no "Stop" yet.
        let result = IndoorComposer.compose([object("Chair", ahead: 1.2, right: -0.15)], pose: pose)
        #expect(result.guidance.hasPrefix("Step right to pass."))
        #expect(result.summary.last == "Step right to pass.")
        #expect(result.alert == nil)
    }

    @Test func veryCloseMeansStop() throws {
        let result = IndoorComposer.compose([object("Table", ahead: 0.6, right: 0)], pose: pose)
        #expect(result.guidance.hasPrefix("Stop."))
        let alert = try #require(result.alert)
        #expect(alert.severity == .stop)
        #expect(alert.headline == "Stop. Table right in front of you.")
    }

    @Test func aDoorRightInFrontIsNotAStop() {
        let result = IndoorComposer.compose([door(open: false, ahead: 0.5)], pose: pose)
        #expect(result.alert == nil)
        #expect(result.summary.last == IndoorComposer.closedDoorGuidance)
    }

    @Test func stairsWarnEarly() throws {
        let stairs = object("Stairs", ahead: 1.3, right: 0, size: 1, category: .stairs)
        let alert = try #require(IndoorComposer.compose([stairs], pose: pose).alert)
        #expect(alert.severity == .stop)
        #expect(alert.guidance.contains("railing"))
    }

    @Test func wallStraightAhead() {
        let result = IndoorComposer.compose([wall(from: (1.5, -3), to: (1.5, 3))], pose: pose)
        #expect(result.headline == "Wall 2 steps straight ahead.")
        #expect(result.guidance.hasPrefix("Wall ahead. Turn left or right."))
    }

    @Test func thingsBehindAreNotTheHeadline() {
        let result = IndoorComposer.compose([object("Chair", ahead: -1.5, right: 0)], pose: pose)
        #expect(result.headline == "The way ahead is clear.")
    }

    @Test func aStepCloserDoesNotChangeTheSummaryKey() {
        let id = UUID()
        let far = IndoorComposer.compose([object("Chair", ahead: 2.0, right: 0, id: id)], pose: pose)
        let near = IndoorComposer.compose([object("Chair", ahead: 1.8, right: 0, id: id)], pose: pose)
        #expect(far.headline != near.headline)
        #expect(far.summaryKey == near.summaryKey)
    }

    @Test func roomSizeFromItsWalls() throws {
        let room = [wall(from: (-1, -2), to: (5, -2)), wall(from: (5, -2), to: (5, 2)), wall(from: (-1, 2), to: (5, 2))]
        let size = try #require(IndoorComposer.compose(room, pose: pose).roomSize)
        #expect(abs(size.length - 6) < 0.01)
        #expect(abs(size.width - 4) < 0.01)
        #expect(IndoorNavigator.overview(size: size, doors: 2) == "This room is about 20 by 15 feet, with 2 doors.")
    }

    @Test func onlyWhatMattersIsOutlined() {
        let path = object("Chair", ahead: 1.5, right: 0)
        let aside = object("Cabinet", ahead: 1, right: 2.5)
        let result = IndoorComposer.compose([path, aside, wall(from: (-1, -3), to: (6, -3))], pose: pose)
        #expect(result.relevant.contains(path.id))
        #expect(!result.relevant.contains(aside.id))
    }

    @Test func miniMapPutsThingsAheadAboveTheUser() throws {
        let result = IndoorComposer.compose([object("Chair", ahead: 2, right: 1)], pose: pose)
        let item = try #require(result.miniMap.first)
        #expect(item.rect.midY < 0.81)  // ahead = up
        #expect(item.rect.midX > 0.5)   // right = right
    }
}

struct IndoorNavigatorTests {
    private let start = Date(timeIntervalSince1970: 0)

    private func said(_ outputs: [IndoorNavigator.Output]) -> [String] {
        outputs.compactMap { if case .say(let pieces) = $0 { pieces.joined(separator: " ") } else { nil } }
    }

    @Test func staysQuietWhenNothingChanges() {
        var navigator = IndoorNavigator()
        let scene = IndoorComposer.compose([object("Chair", ahead: 2, right: 0)], pose: pose)
        #expect(said(navigator.update(scene, canSpeak: true, now: start)).isEmpty)
        #expect(said(navigator.update(scene, canSpeak: true, now: start.addingTimeInterval(5))) == ["Chair 3 steps straight ahead. Step right to pass."])
        for t in stride(from: 6.0, through: 60, by: 1) {
            #expect(said(navigator.update(scene, canSpeak: true, now: start.addingTimeInterval(t))).isEmpty)
        }
    }

    @Test func stopIsSaidOnce() {
        var navigator = IndoorNavigator()
        let scene = IndoorComposer.compose([object("Table", ahead: 0.6, right: 0)], pose: pose)
        let first = navigator.update(scene, canSpeak: true, now: start)
        #expect(first.contains { if case .urgent = $0 { true } else { false } })
        for t in 1...20 {
            #expect(!navigator.update(scene, canSpeak: true, now: start.addingTimeInterval(Double(t))).contains { if case .urgent = $0 { true } else { false } })
        }
    }

    @Test func guidesToTheDoorAndSaysWhenYouArrive() {
        var navigator = IndoorNavigator()
        let id = UUID()
        func scene(ahead: Double, right: Double, facing: SIMD2<Double> = SIMD2(0, -1)) -> IndoorComposer.Result {
            IndoorComposer.compose([door(open: true, ahead: ahead, right: right, id: id)], pose: FloorPose(position: .zero, forward: facing))
        }
        let start = navigator.startGuiding(scene(ahead: 4, right: -3), now: self.start)
        #expect(said(start) == ["Door 7 steps ahead, on your left. Turn slightly left."])
        #expect(navigator.isGuiding)

        // Turned to face it: a tap, and "walk straight".
        let turned = navigator.update(scene(ahead: 5, right: 0), canSpeak: true, now: self.start.addingTimeInterval(4))
        #expect(turned.contains(.aligned))
        #expect(said(turned) == ["Door 7 steps straight ahead. Walk straight."])

        // At the door.
        let there = navigator.update(scene(ahead: 0.6, right: 0), canSpeak: true, now: self.start.addingTimeInterval(10))
        #expect(said(there) == ["You're at the door. It's open."])
        #expect(!navigator.isGuiding)
    }

    @Test func aClosedDoorAlsoSaysHowToOpenIt() {
        var navigator = IndoorNavigator()
        let scene = IndoorComposer.compose([door(open: false, ahead: 0.7)], pose: pose)
        let outputs = navigator.startGuiding(scene, now: start)
        #expect(said(outputs) == ["You're at the door. \(IndoorComposer.closedDoorGuidance)"])
        #expect(outputs.contains(.describeDoor))
    }

    @Test func noDoorYetKeepsLookingThenAsksTheCamera() {
        var navigator = IndoorNavigator()
        let empty = IndoorComposer.compose([], pose: pose)
        #expect(said(navigator.startGuiding(empty, now: start)).first == "I haven't found a door yet. Turn slowly, and I'll tell you when I see one.")
        #expect(navigator.update(empty, canSpeak: true, now: start.addingTimeInterval(7)).contains(.lookForDoor))
        let found = navigator.update(IndoorComposer.compose([door(open: true, ahead: 3)], pose: pose), canSpeak: true,
                                     now: start.addingTimeInterval(9))
        #expect(said(found).first == "Found a door.")
    }
}
