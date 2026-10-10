import CoreGraphics
import Foundation
import Testing
@testable import Resonate

private func item(_ label: String, _ category: ObjectCategory, _ box: CGRect, distance: Double = 3) -> DetectedObject {
    DetectedObject(label: label, category: category, confidence: 0.9, boundingBox: box, distanceMeters: distance)
}

struct SceneGroupingTests {
    private let walker = item("Person", .person, CGRect(x: 0.4, y: 0.2, width: 0.15, height: 0.6))

    @Test func aBagSomeoneCarriesIsPartOfThem() {
        let bag = item("Bag", .obstacle, CGRect(x: 0.42, y: 0.45, width: 0.08, height: 0.12))
        #expect(SceneGrouping.group([walker, bag]).map(\.label) == ["Person"])
    }

    @Test func aBagLeftOnTheGroundStillCounts() {
        let bag = item("Bag", .obstacle, CGRect(x: 0.1, y: 0.7, width: 0.08, height: 0.1), distance: 1.5)
        #expect(Set(SceneGrouping.group([walker, bag]).map(\.label)) == ["Person", "Bag"])
    }

    @Test func aPersonOnABikeIsACyclist() {
        let rider = item("Person", .person, CGRect(x: 0.4, y: 0.15, width: 0.15, height: 0.5))
        let bike = item("Bike", .vehicle, CGRect(x: 0.35, y: 0.45, width: 0.25, height: 0.3))
        let grouped = SceneGrouping.group([rider, bike])
        #expect(grouped.map(\.label) == ["Cyclist"])
        #expect(grouped.first?.category == .vehicle)
    }

    @Test func aParkedBikeNextToSomeoneIsStillABike() {
        let bike = item("Bike", .vehicle, CGRect(x: 0.7, y: 0.5, width: 0.2, height: 0.25))
        #expect(Set(SceneGrouping.group([walker, bike]).map(\.label)) == ["Person", "Bike"])
    }

    @Test func someoneSittingHidesTheSeat() {
        let sitter = item("Person", .person, CGRect(x: 0.4, y: 0.3, width: 0.15, height: 0.4))
        let bench = item("Seat", .furniture, CGRect(x: 0.35, y: 0.5, width: 0.3, height: 0.2))
        #expect(SceneGrouping.group([sitter, bench]).map(\.label) == ["Person"])
    }

    @Test func peopleTogetherAreOneGroup() {
        let a = item("Person", .person, CGRect(x: 0.3, y: 0.2, width: 0.12, height: 0.6), distance: 4)
        let b = item("Person", .person, CGRect(x: 0.41, y: 0.2, width: 0.12, height: 0.6), distance: 3.5)
        let c = item("Person", .person, CGRect(x: 0.52, y: 0.2, width: 0.12, height: 0.6), distance: 4.2)
        let grouped = SceneGrouping.group([a, b, c])
        #expect(grouped.map(\.label) == ["People"])
        #expect(grouped.first?.distanceMeters == 3.5)
    }

    @Test func peopleFarApartStaySeparate() {
        let a = item("Person", .person, CGRect(x: 0.1, y: 0.2, width: 0.12, height: 0.6))
        let b = item("Person", .person, CGRect(x: 0.7, y: 0.2, width: 0.12, height: 0.6))
        #expect(SceneGrouping.group([a, b]).map(\.label) == ["Person", "Person"])
    }
}
