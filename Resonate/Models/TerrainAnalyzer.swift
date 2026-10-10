import CoreGraphics
import Foundation

/// One LiDAR depth sample turned into walking-frame coordinates (gravity-aligned, relative to the phone).
nonisolated struct TerrainSample: Sendable {
    /// Meters ahead along the direction the phone faces (flattened to horizontal).
    var forward: Double
    /// Meters to the right (negative = left).
    var lateral: Double
    /// Height in meters relative to the phone (negative = below it).
    var height: Double
    /// Vertical position in the upright camera image (0 = top, 1 = bottom), for drawing the overlay.
    var imageY: Double
}

/// Finds what YOLO can't: curb drops and other drop-offs, steps up, and unlabeled things in the
/// way (poles, posts, walls, low branches), from LiDAR depth in a corridor ahead of the user.
/// Pure geometry, so it is easy to test.
nonisolated enum TerrainAnalyzer {
    nonisolated enum Kind: Sendable {
        case dropOff
        case stepUp
        case obstacle
    }

    nonisolated struct Finding: Sendable, Equatable {
        var kind: Kind
        /// Meters ahead.
        var distance: Double
        /// How big the height change is (drop or step), in meters.
        var heightChange: Double
        var imageY: Double
    }

    /// Half-width of the walking corridor checked for hazards.
    static let corridorHalfWidth = 0.45
    /// A level change this big counts as a curb or step.
    static let edgeThreshold = 0.12
    /// Higher than this above the ground is an obstacle, not a step.
    static let stepMaxHeight = 0.35
    /// Things between these heights above the ground, within `obstacleRange`, are in the way.
    static let obstacleMinHeight = 0.3
    static let obstacleMaxHeight = 2.1
    static let obstacleRange = 2.5
    static let binSize = 0.3

    static func analyze(_ samples: [TerrainSample]) -> [Finding] {
        let corridor = samples.filter { abs($0.lateral) <= corridorHalfWidth && (0.3...5).contains($0.forward) }

        // The ground right in front of the user. A low percentile ignores objects standing on it.
        let near = corridor.filter { (0.6...1.6).contains($0.forward) }.map(\.height)
        guard near.count >= 10, let ground = percentile(near, 0.3) else { return [] }

        var findings: [Finding] = []

        // Something in the way at body height.
        let blocking = corridor.filter {
            $0.forward <= obstacleRange
                && (ground + obstacleMinHeight...ground + obstacleMaxHeight).contains($0.height)
        }
        if blocking.count >= 6, let distance = percentile(blocking.map(\.forward), 0.1) {
            findings.append(Finding(kind: .obstacle, distance: distance, heightChange: 0,
                                    imageY: mean(blocking.map(\.imageY))))
        }

        // Walk outward bin by bin, following gentle slopes, looking for a sudden level change.
        var level = ground
        var bins: [(start: Double, height: Double, imageY: Double)] = []
        var start = 0.9
        while start < 5 {
            let inBin = corridor.filter { $0.forward >= start && $0.forward < start + binSize }
            if inBin.count >= 5, let median = percentile(inBin.map(\.height), 0.5) {
                bins.append((start, median, mean(inBin.map(\.imageY))))
            }
            start += binSize
        }
        for (index, bin) in bins.enumerated() {
            let change = bin.height - level
            // A drop must hold for the next bin too, so one noisy bin isn't a curb.
            let nextAlsoLow = index + 1 >= bins.count || bins[index + 1].height - level < -edgeThreshold
            if change < -edgeThreshold, nextAlsoLow {
                findings.append(Finding(kind: .dropOff, distance: bin.start, heightChange: -change, imageY: bin.imageY))
                break
            }
            if change > edgeThreshold, change < stepMaxHeight {
                findings.append(Finding(kind: .stepUp, distance: bin.start, heightChange: change, imageY: bin.imageY))
                break
            }
            if abs(change) <= edgeThreshold { level = bin.height }
        }

        return findings
    }

    /// Turns findings into detections for the overlay and the alert composer.
    static func objects(from findings: [Finding]) -> [DetectedObject] {
        findings.map { finding in
            let y = min(max(finding.imageY, 0.05), 0.95)
            switch finding.kind {
            case .dropOff:
                return DetectedObject(label: finding.heightChange > 0.3 ? "Drop-off" : "Curb drop", category: .dropOff,
                                      confidence: 1, boundingBox: CGRect(x: 0.1, y: y - 0.02, width: 0.8, height: 0.04),
                                      distanceMeters: finding.distance)
            case .stepUp:
                return DetectedObject(label: "Step up", category: .stairs, confidence: 1,
                                      boundingBox: CGRect(x: 0.1, y: y - 0.02, width: 0.8, height: 0.04),
                                      distanceMeters: finding.distance)
            case .obstacle:
                return DetectedObject(label: "Obstacle", category: .obstacle, confidence: 1,
                                      boundingBox: CGRect(x: 0.35, y: max(y - 0.12, 0), width: 0.3, height: 0.24),
                                      distanceMeters: finding.distance)
            }
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(Int(Double(sorted.count - 1) * p), sorted.count - 1)]
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0.5 : values.reduce(0, +) / Double(values.count)
    }
}
