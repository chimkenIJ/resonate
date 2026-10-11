import CoreGraphics
import Foundation

/// Folds things that belong together into one, the way a person would describe them:
/// - A bag someone is carrying, or a pet right at their feet, is part of that person.
/// - A person on a bike is one "Cyclist".
/// - Someone sitting on a bench is just a person (the seat is under them).
/// - People standing together are one group, "People".
/// Pure logic on one frame's detections, so it is easy to test.
nonisolated enum SceneGrouping {
    static let cyclist = "Cyclist"
    static let people = "People"
    static var labels: [String] { [cyclist, people] }

    private static let person = "Person"
    /// Things people carry. They move with the person and aren't obstacles on their own.
    private static let carried: Set<String> = ["Bag"]

    static func group(_ objects: [DetectedObject]) -> [DetectedObject] {
        var persons = objects.filter { $0.label == person }
        var others = objects.filter { $0.label != person }
        guard !persons.isEmpty else { return objects }

        // Carried bags and pets right beside someone.
        others.removeAll { item in
            let isCarried = carried.contains(item.label)
            guard isCarried || item.label == "Animal" else { return false }
            return persons.contains { p in
                sameDepth(item, p) && containment(item.boundingBox, in: p.boundingBox.insetBy(dx: -0.03, dy: -0.03)) >= (isCarried ? 0.5 : 0.4)
            }
        }

        // A person riding a bike: one cyclist where the bike is.
        others = others.map { item in
            guard item.label == "Bike", let index = persons.firstIndex(where: { isRiding($0, item) }) else { return item }
            let rider = persons.remove(at: index)
            var cyclist = item
            cyclist.label = Self.cyclist
            cyclist.boundingBox = item.boundingBox.union(rider.boundingBox)
            cyclist.distanceMeters = nearest(item.distanceMeters, rider.distanceMeters)
            return cyclist
        }

        // Someone sitting: the seat under them isn't a separate obstacle.
        others.removeAll { item in
            item.label == "Seat" && persons.contains { sameDepth(item, $0) && containment(item.boundingBox, in: $0.boundingBox) >= 0.25 }
        }

        return others + groupPeople(persons)
    }

    /// People whose boxes touch and who stand at about the same distance become one "People".
    private static func groupPeople(_ persons: [DetectedObject]) -> [DetectedObject] {
        var clusters: [[DetectedObject]] = []
        for p in persons {
            let joined = clusters.indices.filter { i in clusters[i].contains { near(p, $0) } }
            var merged = joined.flatMap { clusters[$0] } + [p]
            for i in joined.reversed() { clusters.remove(at: i) }
            merged.sort { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
            clusters.append(merged)
        }
        return clusters.map { cluster in
            guard cluster.count > 1, var group = cluster.first else { return cluster[0] }
            // Described by its nearest member: where it is and how far.
            group.label = people
            group.boundingBox = cluster.dropFirst().reduce(group.boundingBox) { $0.union($1.boundingBox) }
            return group
        }
    }

    // MARK: Geometry

    /// Share of `a`'s area inside `b`.
    static func containment(_ a: CGRect, in b: CGRect) -> Double {
        let overlap = a.intersection(b)
        guard !overlap.isNull, a.width > 0, a.height > 0 else { return 0 }
        return Double(overlap.width * overlap.height / (a.width * a.height))
    }

    private static func sameDepth(_ a: DetectedObject, _ b: DetectedObject, within: Double = 1.0) -> Bool {
        guard let da = a.distanceMeters, let db = b.distanceMeters else { return true }
        return abs(da - db) <= within
    }

    /// Their lower body over the bike, at the same distance.
    private static func isRiding(_ rider: DetectedObject, _ bike: DetectedObject) -> Bool {
        let p = rider.boundingBox, b = bike.boundingBox
        return sameDepth(rider, bike, within: 1.5)
            && (b.minX...b.maxX).contains(p.midX)
            && p.maxY >= b.minY && p.maxY <= b.maxY + 0.05
    }

    /// Boxes overlapping or nearly touching side by side, at about the same distance.
    private static func near(_ a: DetectedObject, _ b: DetectedObject) -> Bool {
        let gap = max(a.boundingBox.minX, b.boundingBox.minX) - min(a.boundingBox.maxX, b.boundingBox.maxX)
        return gap <= 0.04 && sameDepth(a, b, within: 1.2)
    }

    private static func nearest(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (a?, b?): min(a, b)
        case let (a?, nil): a
        case let (nil, b): b
        }
    }
}
