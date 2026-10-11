import CoreGraphics
import Foundation
import Testing
@testable import Resonate

/// The phone at chest height, 1.3 m above a flat floor.
private let floor = -1.3

/// Floor points ahead, like the LiDAR sees them.
private func floorPoints() -> [TerrainSample] {
    stride(from: 0.5, through: 4, by: 0.1).flatMap { forward in
        stride(from: -2.0, through: 2, by: 0.1).map { lateral in
            TerrainSample(forward: forward, lateral: lateral, height: floor, imageY: 0.9, imageX: 0.5 + lateral / 4)
        }
    }
}

/// A thing on the floor: points on its front face every 2.5 cm (about what LiDAR gives 1–3 m away).
private func thing(ahead: Double, right: Double, width: Double, height: Double) -> [TerrainSample] {
    stride(from: right - width / 2, through: right + width / 2, by: 0.025).flatMap { lateral in
        stride(from: floor + 0.02, through: floor + height, by: 0.025).map { h in
            TerrainSample(forward: ahead, lateral: lateral, height: h, imageY: 0.6, imageX: 0.5 + lateral / 4)
        }
    }
}

struct IndoorObstaclesTests {
    @Test func findsTheFloor() throws {
        let level = try #require(IndoorObstacles.floorLevel(floorPoints()))
        #expect(abs(level - floor) < 0.01)
    }

    @Test func findsAHazardConeNobodyNamed() throws {
        let found = IndoorObstacles.find(floorPoints() + thing(ahead: 2, right: 0.8, width: 0.3, height: 0.5), floor: floor)
        let cone = try #require(found.first)
        #expect(found.count == 1)
        #expect(abs(cone.forward - 2) < 0.1)
        #expect(abs(cone.lateral - 0.8) < 0.1)
        #expect(abs(cone.height - 0.5) < 0.05)
    }

    @Test func findsALowBoxToo() {
        #expect(IndoorObstacles.find(floorPoints() + thing(ahead: 1.5, right: -0.3, width: 0.4, height: 0.15), floor: floor).count == 1)
    }

    @Test func twoThingsApartAreTwoObstacles() {
        let found = IndoorObstacles.find(floorPoints()
            + thing(ahead: 2, right: -1, width: 0.3, height: 0.6)
            + thing(ahead: 3, right: 1, width: 0.4, height: 0.4), floor: floor)
        #expect(found.count == 2)
        #expect(found.first.map { abs($0.forward - 2) < 0.1 } == true) // nearest first
    }

    @Test func aFlatFloorAndARugAreNothing() {
        #expect(IndoorObstacles.find(floorPoints() + thing(ahead: 2, right: 0, width: 1, height: 0.04), floor: floor).isEmpty)
    }

    @Test func aWallIsNotAnObstacle() {
        // Walls are mapped by the room scan; here they're too wide to be a thing on the floor.
        #expect(IndoorObstacles.find(floorPoints() + thing(ahead: 3, right: 0, width: 3.5, height: 1.8), floor: floor).isEmpty)
    }
}
