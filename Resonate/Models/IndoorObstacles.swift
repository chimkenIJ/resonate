import CoreGraphics
import Foundation

/// Finds things standing on the floor from LiDAR depth alone, whatever they are: a hazard cone, a
/// box, a bin, a chair the camera hasn't named yet. Indoors only (floors are flat, so anything a few
/// centimeters above it is something). Things nobody recognizes are still detected, and called
/// "Obstacle". Pure geometry, so it is easy to test.
nonisolated enum IndoorObstacles {
    nonisolated struct Found: Sendable, Equatable {
        /// Middle of it, meters ahead and to the right of the user.
        var forward: Double
        var lateral: Double
        /// Straight-line distance to its nearest point.
        var distance: Double
        /// Size on the floor (meters) and how tall it is above the floor.
        var width: Double
        var depth: Double
        var height: Double
        /// Where it is in the upright camera image (normalized), for the outline.
        var box: CGRect
    }

    /// Anything at least this high above the floor counts (rugs and floor noise don't).
    static let minHeight = 0.08
    /// Up to this high: higher points are walls, shelves, and ceilings.
    static let maxHeight = 1.9
    static let range = 4.0
    static let sideRange = 2.0
    /// Floor grid for grouping points into separate things.
    static let cellSize = 0.2
    static let minPointsPerCell = 3
    static let minPoints = 8
    /// Wider or deeper than this is a wall or a big piece of furniture, which RoomPlan maps itself.
    static let maxExtent = 1.6
    static let maxReported = 6

    /// The floor's height relative to the phone, from the lowest points ahead. Nil when the floor isn't in view.
    static func floorLevel(_ samples: [TerrainSample]) -> Double? {
        let ahead = samples.filter { (0.5...range).contains($0.forward) && abs($0.lateral) <= 1.5 }.map(\.height)
        guard ahead.count >= 30 else { return nil }
        return TerrainAnalyzer.percentile(ahead, 0.1)
    }

    /// Separate things standing on the floor, nearest first.
    static func find(_ samples: [TerrainSample], floor: Double) -> [Found] {
        let above = samples.filter {
            (0.3...range).contains($0.forward) && abs($0.lateral) <= sideRange
                && (floor + minHeight...floor + maxHeight).contains($0.height)
        }
        struct Cell: Hashable { var x: Int; var y: Int }
        var cells: [Cell: [TerrainSample]] = [:]
        for sample in above {
            cells[Cell(x: Int((sample.forward / cellSize).rounded(.down)), y: Int((sample.lateral / cellSize).rounded(.down))), default: []]
                .append(sample)
        }
        var occupied = Set(cells.filter { $0.value.count >= minPointsPerCell }.keys)

        // Touching cells are one thing.
        var found: [Found] = []
        while let seed = occupied.first {
            occupied.remove(seed)
            var group = [seed], queue = [seed]
            while let cell = queue.popLast() {
                for dx in -1...1 {
                    for dy in -1...1 {
                        let next = Cell(x: cell.x + dx, y: cell.y + dy)
                        if occupied.remove(next) != nil {
                            group.append(next)
                            queue.append(next)
                        }
                    }
                }
            }
            let points = group.flatMap { cells[$0] ?? [] }
            guard points.count >= minPoints else { continue }
            let forwards = points.map(\.forward), laterals = points.map(\.lateral)
            let width = laterals.max()! - laterals.min()!, depth = forwards.max()! - forwards.min()!
            guard max(width, depth) <= maxExtent else { continue }
            let xs = points.map(\.imageX), ys = points.map(\.imageY)
            found.append(Found(
                forward: forwards.reduce(0, +) / Double(points.count),
                lateral: laterals.reduce(0, +) / Double(points.count),
                distance: points.map { ($0.forward * $0.forward + $0.lateral * $0.lateral).squareRoot() }.min()!,
                width: width,
                depth: depth,
                height: points.map(\.height).max()! - floor,
                box: CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 0.02), height: max(ys.max()! - ys.min()!, 0.02))
            ))
        }
        return Array(found.sorted { $0.distance < $1.distance }.prefix(maxReported))
    }
}
