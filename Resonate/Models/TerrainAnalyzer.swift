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
        case stairsUp
        case stairsDown
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
    /// Stairs: the ground keeps rising (or falling) steeply for at least `stairsMinRun` meters.
    /// Ramps are much gentler (at most about 8%), and a single curb or step is over within one bin.
    static let stairsMinRun = 0.85
    static let stairsMinRise = 0.3
    static let stairsMinGrade = 0.35

    static func analyze(_ samples: [TerrainSample]) -> [Finding] {
        let corridor = samples.filter { abs($0.lateral) <= corridorHalfWidth && (0.3...5).contains($0.forward) }

        // The ground right in front of the user. A low percentile ignores objects standing on it.
        let near = corridor.filter { (0.6...1.6).contains($0.forward) }.map(\.height)
        guard near.count >= 10, let ground = percentile(near, 0.3) else { return [] }

        // Ground height in bins outward from the user.
        var bins: [Bin] = []
        var start = 0.9
        while start < 5 {
            let inBin = corridor.filter { $0.forward >= start && $0.forward < start + binSize }
            if inBin.count >= 5, let median = percentile(inBin.map(\.height), 0.5) {
                bins.append(Bin(start: start, height: median, imageY: mean(inBin.map(\.imageY))))
            }
            start += binSize
        }

        var findings: [Finding] = []
        let stairs = findStairs(in: bins)

        // Something in the way at body height. Rising stairs reach that height too; they're not an obstacle.
        let blocking = corridor.filter {
            $0.forward <= obstacleRange
                && (ground + obstacleMinHeight...ground + obstacleMaxHeight).contains($0.height)
        }
        if blocking.count >= 6, let distance = percentile(blocking.map(\.forward), 0.1),
           !(stairs?.kind == .stairsUp && distance >= stairs!.distance - 0.3) {
            findings.append(Finding(kind: .obstacle, distance: distance, heightChange: 0,
                                    imageY: mean(blocking.map(\.imageY))))
        }

        if let stairs {
            findings.append(stairs)
            return findings
        }

        // Walk outward bin by bin, following gentle slopes, looking for a sudden level change.
        var level = ground
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

    /// How far ahead each sector is free of anything at body height: straight ahead, and a step to the
    /// left and right. Nil when the ground isn't visible (phone pointing up or down).
    static func clearance(_ samples: [TerrainSample], range: Double = 4) -> PathClearance? {
        let near = samples.filter { abs($0.lateral) <= corridorHalfWidth && (0.6...1.6).contains($0.forward) }.map(\.height)
        guard near.count >= 10, let ground = percentile(near, 0.3) else { return nil }
        let blocking = samples.filter {
            (0.3...range).contains($0.forward) && (ground + obstacleMinHeight...ground + obstacleMaxHeight).contains($0.height)
        }
        func sector(_ lateral: ClosedRange<Double>) -> Double? {
            let inSector = blocking.filter { lateral.contains($0.lateral) }
            return inSector.count >= 6 ? percentile(inSector.map(\.forward), 0.1) : nil
        }
        return PathClearance(left: sector(-1.2 ... -0.4), center: sector(-0.4...0.4), right: sector(0.4...1.2))
    }

    private struct Bin {
        var start: Double
        var height: Double
        var imageY: Double
    }

    /// The nearest place where the ground climbs or drops steeply and steadily, like a flight of stairs.
    private static func findStairs(in bins: [Bin]) -> Finding? {
        for i in bins.indices {
            var j = i
            while j + 1 < bins.count, bins[j + 1].start - bins[j].start <= binSize * 2.05, j - i < 8 {
                j += 1
                let run = bins[j].start - bins[i].start
                let rise = bins[j].height - bins[i].height
                guard run >= stairsMinRun, abs(rise) >= stairsMinRise, abs(rise) / run >= stairsMinGrade else { continue }
                // Steadily one way, one riser at a time: no bin goes back against the stairs, and none
                // jumps more than a step (a car hood or a wall jumps much more).
                let steady = (i..<j).allSatisfy { k in
                    let step = bins[k + 1].height - bins[k].height
                    return abs(step) <= stepMaxHeight && (rise > 0 ? step >= -0.04 : step <= 0.04)
                }
                guard steady else { continue }
                // The stairs start where the ground first leaves the level it was at.
                let first = (i + 1...j).first { abs(bins[$0].height - bins[i].height) > 0.06 } ?? i
                return Finding(kind: rise > 0 ? .stairsUp : .stairsDown, distance: bins[first].start,
                               heightChange: abs(rise), imageY: bins[first].imageY)
            }
        }
        return nil
    }

    /// Turns findings into detections for the overlay and the alert composer.
    static func objects(from findings: [Finding]) -> [DetectedObject] {
        findings.map { finding in
            let y = min(max(finding.imageY, 0.05), 0.95)
            switch finding.kind {
            case .dropOff:
                return DetectedObject(label: finding.heightChange > 0.3 ? "Drop-off" : "Curb drop", category: .dropOff,
                                      confidence: 1, boundingBox: CGRect(x: 0.1, y: y - 0.02, width: 0.8, height: 0.04),
                                      distanceMeters: finding.distance, lateralMeters: 0)
            case .stepUp:
                return DetectedObject(label: "Step up", category: .stairs, confidence: 1,
                                      boundingBox: CGRect(x: 0.1, y: y - 0.02, width: 0.8, height: 0.04),
                                      distanceMeters: finding.distance, lateralMeters: 0)
            case .stairsUp, .stairsDown:
                return DetectedObject(label: finding.kind == .stairsUp ? stairsUpLabel : stairsDownLabel, category: .stairs,
                                      confidence: 1, boundingBox: CGRect(x: 0.1, y: max(y - 0.08, 0), width: 0.8, height: 0.16),
                                      distanceMeters: finding.distance, lateralMeters: 0)
            case .obstacle:
                return DetectedObject(label: "Obstacle", category: .obstacle, confidence: 1,
                                      boundingBox: CGRect(x: 0.35, y: max(y - 0.12, 0), width: 0.3, height: 0.24),
                                      distanceMeters: finding.distance, lateralMeters: 0)
            }
        }
    }

    static let stairsUpLabel = "Stairs going up"
    static let stairsDownLabel = "Stairs going down"

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(Int(Double(sorted.count - 1) * p), sorted.count - 1)]
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0.5 : values.reduce(0, +) / Double(values.count)
    }
}
