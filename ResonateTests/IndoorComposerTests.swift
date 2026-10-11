import CoreGraphics
import Foundation
import simd
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
        // The wall alongside isn't mentioned; nothing says which way to go.
        #expect(result.headline == "Door 7 steps straight ahead.")
        #expect(result.guidance == "Door 7 steps straight ahead.")
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
        #expect(result.headline == "Nothing in front of you.")
        #expect(result.summary == ["Clear ahead."])
    }

    @Test func somethingInThePathIsDescribedNotSteeredAround() {
        // Chair slightly left of center, 1.2 m ahead: said where it is, no "Stop" yet, no advice.
        let result = IndoorComposer.compose([object("Chair", ahead: 1.2, right: -0.15)], pose: pose)
        #expect(result.summary.first == "Chair")
        #expect(!result.summary.contains { $0.contains("pass") || $0.hasPrefix("Turn") || $0.hasPrefix("Step") })
        #expect(result.alert == nil)
    }

    @Test func saysWhatsInFrontLeftToRight() {
        let result = IndoorComposer.compose([
            object("Table", ahead: 2, right: 0),
            object("Chair", ahead: 2.5, right: 1.5),
            object("Couch", ahead: 2.5, right: -1.5, size: 1),
        ], pose: pose)
        #expect(result.summary.filter { ["Couch", "Table", "Chair"].contains($0) } == ["Couch", "Table", "Chair"])
        #expect(result.headline == "Left to right: Couch, Table, Chair.")
    }

    @Test func veryCloseMeansStop() throws {
        let result = IndoorComposer.compose([object("Table", ahead: 0.6, right: 0)], pose: pose)
        let alert = try #require(result.alert)
        #expect(alert.severity == .stop)
        #expect(alert.headline == "Stop. Table right in front of you.")
        #expect(alert.spokenText == "Stop. Table right in front of you.")
    }

    @Test func aDoorRightInFrontIsNotAStop() {
        let result = IndoorComposer.compose([door(open: false, ahead: 0.5)], pose: pose)
        #expect(result.alert == nil)
        #expect(result.summary.last == "It's closed.")
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
        #expect(result.guidance == "Wall 2 steps straight ahead.")
    }

    @Test func thingsBehindAreNotTheHeadline() {
        let result = IndoorComposer.compose([object("Chair", ahead: -1.5, right: 0)], pose: pose)
        #expect(result.headline == "Nothing in front of you.")
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
        let aside = object("Cabinet", ahead: 1, right: 3.8)
        let result = IndoorComposer.compose([path, aside, wall(from: (-1, -3), to: (6, -3))], pose: pose)
        #expect(result.relevant.contains(path.id))
        #expect(!result.relevant.contains(aside.id))
    }

    @Test func mentionsWhatsNearbyByName() {
        let chair = object("Chair", ahead: 2, right: -1.5)
        let plant = object("Plant", ahead: 2.6, right: 1.4, category: .obstacle)
        let result = IndoorComposer.compose([chair, plant], pose: pose)
        #expect(result.summary.joined(separator: " ") == "Chair 3 steps ahead, on your left. Plant 4 steps ahead, on your right.")
        #expect(result.relevant.isSuperset(of: [chair.id, plant.id]))
    }

    @Test func neverMoreThanThreeThingsAtOnce() {
        let things = (0..<6).map { object("Chair", ahead: 1.5 + Double($0) * 0.2, right: $0.isMultiple(of: 2) ? -1.2 : 1.2) }
        let said = IndoorComposer.compose(things, pose: pose).summary.joined(separator: " ")
        #expect(said.components(separatedBy: "Chair").count - 1 == 3)
    }

    @Test func walkingCloserToNearbyThingsDoesNotRepeatThem() {
        let chair = UUID(), table = UUID()
        func scene(_ ahead: Double) -> IndoorComposer.Result {
            IndoorComposer.compose([object("Chair", ahead: ahead, right: -1.3, id: chair),
                                    object("Table", ahead: ahead + 0.5, right: 1.3, id: table)], pose: pose)
        }
        #expect(scene(2.3).summaryKey == scene(1.8).summaryKey)
    }

    @Test func aStepIsNamed() throws {
        let step = object("Step down", ahead: 1.2, right: 0, size: 0.6, category: .dropOff)
        let result = IndoorComposer.compose([step], pose: pose)
        #expect(result.summary.first == "Step down")
        // A single step isn't stairs: no early "Find the railing".
        #expect(result.alert == nil)
    }

    @Test func distanceToAnElement() {
        let chair = object("Chair", ahead: 2, right: 0, size: 0.4)
        #expect(IndoorComposer.distance(from: at(2, 0), to: chair) == 0)
        #expect(abs(IndoorComposer.distance(from: at(2, 1.2), to: chair) - 1.0) < 1e-9)
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
        #expect(said(navigator.update(scene, canSpeak: true, now: start.addingTimeInterval(5))) == ["Chair 3 steps straight ahead."])
        for t in stride(from: 6.0, through: 60, by: 1) {
            #expect(said(navigator.update(scene, canSpeak: true, now: start.addingTimeInterval(t))).isEmpty)
        }
    }

    @Test func aRescannedThingDoesntGetAnotherStop() {
        var navigator = IndoorNavigator()
        #expect(navigator.update(IndoorComposer.compose([object("Table", ahead: 0.6, right: 0)], pose: pose), canSpeak: true, now: start)
            .contains { if case .urgent = $0 { true } else { false } })
        // The scan improves and the same table comes back as a new element, renamed.
        for t in 1...10 {
            let rescanned = IndoorComposer.compose([object(t.isMultiple(of: 2) ? "Table" : "Cabinet", ahead: 0.6, right: 0)], pose: pose)
            #expect(!navigator.update(rescanned, canSpeak: true, now: start.addingTimeInterval(Double(t))).contains { if case .urgent = $0 { true } else { false } })
        }
    }

    @Test func onlyWhatsNewInFrontIsSaid() {
        var navigator = IndoorNavigator()
        let couch = object("Couch", ahead: 2.5, right: -1.5, size: 1)
        let table = object("Table", ahead: 2, right: 0)
        _ = navigator.update(IndoorComposer.compose([couch, table], pose: pose), canSpeak: true, now: start)
        #expect(said(navigator.update(IndoorComposer.compose([couch, table], pose: pose), canSpeak: true, now: start.addingTimeInterval(3)))
            == ["Couch 3 steps ahead, on your left. Table 3 steps straight ahead."])
        // Turning a little: the same things on other sides aren't news.
        let turned = FloorPose(position: .zero, forward: simd_normalize(SIMD2(-0.3, -1)))
        #expect(said(navigator.update(IndoorComposer.compose([couch, table], pose: turned), canSpeak: true, now: start.addingTimeInterval(7))).isEmpty)
        // The scan renames the table: still the same table.
        var renamed = table
        renamed.label = "Desk"
        #expect(said(navigator.update(IndoorComposer.compose([couch, renamed], pose: pose), canSpeak: true, now: start.addingTimeInterval(11))).isEmpty)
        // A chair comes into view: only the chair.
        let chair = object("Chair", ahead: 2.5, right: 1.5)
        #expect(said(navigator.update(IndoorComposer.compose([couch, table, chair], pose: pose), canSpeak: true, now: start.addingTimeInterval(15)))
            == ["Chair 4 steps ahead, on your right."])
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

    @Test func findDoorSaysWhereTheDoorsAre() {
        let scene = IndoorComposer.compose([door(open: true, ahead: 4, right: -3), door(open: false, ahead: 6, right: 2)], pose: pose)
        #expect(said(IndoorNavigator.findDoor(scene)) == ["Door 7 steps ahead, on your left. Door 9 steps straight ahead. It's closed."])
    }

    @Test func atAClosedDoorFindDoorSaysHowToOpenIt() {
        let scene = IndoorComposer.compose([door(open: false, ahead: 0.7)], pose: pose)
        let outputs = IndoorNavigator.findDoor(scene)
        #expect(said(outputs) == ["Door right in front of you. \(IndoorComposer.closedDoorGuidance)"])
        #expect(outputs.contains(.describeDoor))
    }

    @Test func noDoorYetAsksTheCamera() {
        let outputs = IndoorNavigator.findDoor(IndoorComposer.compose([], pose: pose))
        #expect(said(outputs) == ["I haven't found a door yet."])
        #expect(outputs.contains(.lookForDoor))
    }
}
