import Foundation

/// Which YOLO (COCO) classes matter to someone walking, what to call them out loud, and their
/// typical height, used to estimate distance when there's no LiDAR.
nonisolated enum ObjectCatalog {
    nonisolated struct Entry: Sendable {
        let label: String
        let category: ObjectCategory
        /// Typical height in meters.
        let typicalHeight: Double
    }

    /// COCO class name → entry. Classes not listed (cups, phones, ties…) are ignored.
    /// Names are deliberately general: YOLO often flips between similar classes (car / truck,
    /// chair / bench, dog / cat), and the user only needs to know what kind of thing is in the way.
    static let entries: [String: Entry] = [
        "person": Entry(label: "Person", category: .person, typicalHeight: 1.7),
        "bicycle": Entry(label: "Bike", category: .vehicle, typicalHeight: 1.0),
        "motorcycle": Entry(label: "Bike", category: .vehicle, typicalHeight: 1.1),
        "car": Entry(label: "Vehicle", category: .vehicle, typicalHeight: 1.5),
        "bus": Entry(label: "Vehicle", category: .vehicle, typicalHeight: 3.0),
        "truck": Entry(label: "Vehicle", category: .vehicle, typicalHeight: 2.5),
        "train": Entry(label: "Vehicle", category: .vehicle, typicalHeight: 3.5),
        "stop sign": Entry(label: "Sign", category: .sign, typicalHeight: 0.75),
        "fire hydrant": Entry(label: "Post", category: .obstacle, typicalHeight: 0.7),
        "parking meter": Entry(label: "Post", category: .obstacle, typicalHeight: 1.4),
        "bench": Entry(label: "Seat", category: .furniture, typicalHeight: 0.8),
        "chair": Entry(label: "Seat", category: .furniture, typicalHeight: 0.9),
        "couch": Entry(label: "Seat", category: .furniture, typicalHeight: 0.85),
        "potted plant": Entry(label: "Planter", category: .obstacle, typicalHeight: 0.8),
        "dog": Entry(label: "Animal", category: .obstacle, typicalHeight: 0.5),
        "cat": Entry(label: "Animal", category: .obstacle, typicalHeight: 0.3),
        "suitcase": Entry(label: "Bag", category: .obstacle, typicalHeight: 0.6),
        "backpack": Entry(label: "Bag", category: .obstacle, typicalHeight: 0.5),
        "skateboard": Entry(label: "Obstacle", category: .obstacle, typicalHeight: 0.15),
        "dining table": Entry(label: "Table", category: .furniture, typicalHeight: 0.75),
        "bed": Entry(label: "Bed", category: .furniture, typicalHeight: 0.6),
        "toilet": Entry(label: "Toilet", category: .furniture, typicalHeight: 0.75),
        "refrigerator": Entry(label: "Fridge", category: .furniture, typicalHeight: 1.7),
    ]

    /// Minimum detection confidence to report. High enough that guesses don't get announced.
    static let minimumConfidence: Float = 0.5
    /// Traffic lights are only used to read walk signals, which are small; accept weaker detections.
    static let signalConfidence: Float = 0.3
    /// People are YOLO's most common false alarm (posters, reflections, mannequins, shadows): be stricter.
    static let personConfidence: Float = 0.65

    /// Vehicles are the next most common false alarm (bins, boxes, parked bikes read as cars).
    static let vehicleConfidence: Float = 0.6

    static func minimumConfidence(for identifier: String) -> Float {
        switch identifier {
        case "traffic light": signalConfidence
        case "person": personConfidence
        case "car", "truck", "bus", "train", "motorcycle", "bicycle": vehicleConfidence
        default: minimumConfidence
        }
    }

    /// Whether a measured distance fits the box's size. Something that would have to be far smaller or
    /// larger than usual is probably a false detection (a person on a poster) or a bad depth reading
    /// (LiDAR hitting something in front of a distant person). Boxes cut off by the frame always fit.
    static func sizeFits(typicalHeight: Double, distance: Double, boxHeightPixels: Double,
                         focalLengthPixels: Double, touchesEdge: Bool) -> Bool {
        guard !touchesEdge, typicalHeight >= 0.5, focalLengthPixels > 0 else { return true }
        let impliedHeight = boxHeightPixels / focalLengthPixels * distance
        return (0.35 * typicalHeight...2.2 * typicalHeight).contains(impliedHeight)
    }

    /// Walking outside, the user needs to know *that* something is in the way, not what the detector
    /// guesses it is: a bollard reads as a post one frame and a toilet the next. Everything that stays
    /// put becomes "Obstacle". People, animals, bikes, and vehicles keep their names because they move;
    /// curbs, steps, and stairs keep theirs because they're handled differently.
    static func forWalking(_ object: DetectedObject) -> DetectedObject {
        switch object.category {
        case .person, .vehicle, .stairs, .dropOff: return object
        default:
            guard object.label != "Animal" else { return object }
            var general = object
            general.label = ObstacleTracker.genericLabel
            general.category = .obstacle
            return general
        }
    }

    static func entry(for identifier: String) -> Entry? {
        entries[identifier.lowercased()]
    }

    /// Pinhole estimate: distance = real height × focal length ÷ height in pixels.
    /// Returns nil for boxes cut off by the frame edge (their full height isn't visible) or tiny boxes.
    static func estimatedDistance(typicalHeight: Double, boxHeightPixels: Double, focalLengthPixels: Double,
                                  touchesEdge: Bool) -> Double? {
        guard !touchesEdge, boxHeightPixels >= 12, typicalHeight >= 0.3 else { return nil }
        return typicalHeight * focalLengthPixels / boxHeightPixels
    }
}
