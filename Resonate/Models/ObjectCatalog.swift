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
    static let entries: [String: Entry] = [
        "person": Entry(label: "Person", category: .person, typicalHeight: 1.7),
        "bicycle": Entry(label: "Bike", category: .vehicle, typicalHeight: 1.0),
        "car": Entry(label: "Car", category: .vehicle, typicalHeight: 1.5),
        "motorcycle": Entry(label: "Motorcycle", category: .vehicle, typicalHeight: 1.1),
        "bus": Entry(label: "Bus", category: .vehicle, typicalHeight: 3.0),
        "truck": Entry(label: "Truck", category: .vehicle, typicalHeight: 3.0),
        "train": Entry(label: "Train", category: .vehicle, typicalHeight: 3.5),
        "traffic light": Entry(label: "Traffic light", category: .sign, typicalHeight: 0.9),
        "stop sign": Entry(label: "Stop sign", category: .sign, typicalHeight: 0.75),
        "fire hydrant": Entry(label: "Fire hydrant", category: .obstacle, typicalHeight: 0.7),
        "parking meter": Entry(label: "Parking meter", category: .obstacle, typicalHeight: 1.4),
        "bench": Entry(label: "Bench", category: .furniture, typicalHeight: 0.8),
        "potted plant": Entry(label: "Planter", category: .obstacle, typicalHeight: 0.8),
        "dog": Entry(label: "Dog", category: .obstacle, typicalHeight: 0.5),
        "cat": Entry(label: "Cat", category: .obstacle, typicalHeight: 0.3),
        "suitcase": Entry(label: "Suitcase", category: .obstacle, typicalHeight: 0.6),
        "skateboard": Entry(label: "Skateboard", category: .obstacle, typicalHeight: 0.15),
        "chair": Entry(label: "Chair", category: .furniture, typicalHeight: 0.9),
        "couch": Entry(label: "Couch", category: .furniture, typicalHeight: 0.85),
        "dining table": Entry(label: "Table", category: .furniture, typicalHeight: 0.75),
        "bed": Entry(label: "Bed", category: .furniture, typicalHeight: 0.6),
        "toilet": Entry(label: "Toilet", category: .furniture, typicalHeight: 0.75),
        "refrigerator": Entry(label: "Fridge", category: .furniture, typicalHeight: 1.7),
    ]

    /// Minimum detection confidence to report.
    static let minimumConfidence: Float = 0.4

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
