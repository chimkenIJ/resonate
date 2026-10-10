import CoreGraphics
import Foundation
import Testing
@testable import Resonate

/// Ground samples in a corridor ahead, as the LiDAR would see them with the phone held at chest height.
/// `height(forward)` gives the ground height relative to the phone at each distance.
private func ground(_ height: (Double) -> Double, from start: Double = 0.5, to end: Double = 5) -> [TerrainSample] {
    var samples: [TerrainSample] = []
    var forward = start
    while forward <= end {
        for lateral in stride(from: -0.4, through: 0.4, by: 0.2) {
            samples.append(TerrainSample(forward: forward, lateral: lateral, height: height(forward), imageY: 1 - forward / 6))
        }
        forward += 0.05
    }
    return samples
}

private let chest = -1.3

struct TerrainAnalyzerTests {
    @Test func flatGroundIsClear() {
        #expect(TerrainAnalyzer.analyze(ground { _ in chest }).isEmpty)
    }

    @Test func gentleRampIsNotACurb() {
        // 5% slope down: 22 cm lower after 4.5 m, but never a sudden step.
        #expect(TerrainAnalyzer.analyze(ground { chest - 0.05 * $0 }).isEmpty)
    }

    @Test func findsACurbDrop() throws {
        let findings = TerrainAnalyzer.analyze(ground { $0 < 3 ? chest : chest - 0.15 })
        let drop = try #require(findings.first)
        #expect(drop.kind == .dropOff)
        #expect(abs(drop.distance - 3) <= 0.3)
        #expect(abs(drop.heightChange - 0.15) < 0.02)
        #expect(TerrainAnalyzer.objects(from: findings).first?.label == "Curb drop")
    }

    @Test func aBigDropIsCalledADropOff() {
        let findings = TerrainAnalyzer.analyze(ground { $0 < 2.4 ? chest : chest - 0.6 })
        #expect(TerrainAnalyzer.objects(from: findings).first?.label == "Drop-off")
    }

    @Test func findsAStepUp() throws {
        let findings = TerrainAnalyzer.analyze(ground { $0 < 2.4 ? chest : chest + 0.17 })
        let step = try #require(findings.first)
        #expect(step.kind == .stepUp)
        #expect(abs(step.distance - 2.4) <= 0.3)
    }

    @Test func oneNoisyBinIsNotACurb() {
        // A single low bin (a puddle, a LiDAR glitch), then back to normal.
        let findings = TerrainAnalyzer.analyze(ground { (2.1..<2.4).contains($0) ? chest - 0.2 : chest })
        #expect(findings.isEmpty)
    }

    @Test func findsAPoleInTheWay() throws {
        var samples = ground { _ in chest }
        for height in stride(from: chest + 0.4, through: chest + 1.8, by: 0.1) {
            samples.append(TerrainSample(forward: 1.5, lateral: 0.05, height: height, imageY: 0.45))
        }
        let obstacle = try #require(TerrainAnalyzer.analyze(samples).first { $0.kind == .obstacle })
        #expect(abs(obstacle.distance - 1.5) < 0.05)
    }

    @Test func ignoresThingsOutsideTheWalkingCorridor() {
        var samples = ground { _ in chest }
        for height in stride(from: chest + 0.4, through: chest + 1.8, by: 0.1) {
            samples.append(TerrainSample(forward: 1.5, lateral: 1.2, height: height, imageY: 0.45)) // 1.2 m to the right
        }
        #expect(TerrainAnalyzer.analyze(samples).isEmpty)
    }

    @Test func noGroundInViewMeansNoGuess() {
        // Phone pointed up: nothing near the feet.
        #expect(TerrainAnalyzer.analyze(ground({ _ in chest }, from: 3, to: 5)).isEmpty)
    }
}

struct ObjectCatalogTests {
    @Test func mapsCocoClassesToSpokenLabels() {
        #expect(ObjectCatalog.entry(for: "bicycle")?.label == "Bike")
        #expect(ObjectCatalog.entry(for: "person")?.category == .person)
        #expect(ObjectCatalog.entry(for: "cell phone") == nil)
    }

    @Test func estimatesDistanceFromApparentSize() throws {
        // A 1.7 m person filling 340 px with a 1400 px focal length is 7 m away.
        let distance = try #require(ObjectCatalog.estimatedDistance(typicalHeight: 1.7, boxHeightPixels: 340,
                                                                    focalLengthPixels: 1400, touchesEdge: false))
        #expect(abs(distance - 7) < 0.01)
        // Cut off by the frame edge: its full height isn't visible, so no guess.
        #expect(ObjectCatalog.estimatedDistance(typicalHeight: 1.7, boxHeightPixels: 340, focalLengthPixels: 1400, touchesEdge: true) == nil)
    }

    @Test func namedObjectReplacesTheGenericObstacleAtTheSameSpot() {
        let person = DetectedObject(label: "Person", category: .person, confidence: 0.9,
                                    boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4), distanceMeters: 1.6)
        let generic = DetectedObject(label: "Obstacle", category: .obstacle, confidence: 1,
                                     boundingBox: CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.24), distanceMeters: 1.5)
        let curb = DetectedObject(label: "Curb drop", category: .dropOff, confidence: 1,
                                  boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.04), distanceMeters: 3)
        let merged = FrameAnalysis.merge(labeled: [person], terrain: [generic, curb])
        #expect(merged.map(\.label) == ["Person", "Curb drop"])
    }
}

@MainActor
struct OverlayMappingTests {
    @Test func aspectFillCropsTheSidesOfATallScreen() {
        // 1440×1920 camera image shown on a 390×844 screen: scaled to 633×844, 121.5 pt cut off each side.
        let rect = DetectionOverlay.viewRect(for: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1),
                                             imageSize: CGSize(width: 1440, height: 1920),
                                             in: CGSize(width: 390, height: 844))
        #expect(abs(rect.minX - (-121.5 + 0.5 * 633)) < 0.5)
        #expect(abs(rect.minY - 422) < 0.5)
        #expect(abs(rect.width - 63.3) < 0.5)
    }

    @Test func mockFramesStretchToTheView() {
        let rect = DetectionOverlay.viewRect(for: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1),
                                             imageSize: nil, in: CGSize(width: 400, height: 800))
        #expect(rect == CGRect(x: 200, y: 400, width: 40, height: 80))
    }
}
