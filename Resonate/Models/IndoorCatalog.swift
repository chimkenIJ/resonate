import Foundation

/// What the camera looks for indoors, on top of RoomPlan's furniture, by its real name: indoors the
/// user wants to know what's around them to find their way through a room. (Walking outside uses
/// ObjectCatalog, where anything that stays put is just "Obstacle".)
///
/// Only things worth knowing while moving through a room: furniture, landmarks like the fridge or TV,
/// things on the floor, people and pets. Small tabletop things (cups, phones, books) are left out so
/// the user isn't flooded.
nonisolated enum IndoorCatalog {
    typealias Entry = ObjectCatalog.Entry

    /// COCO class name → entry, with a typical height for estimating distance without LiDAR.
    static let entries: [String: Entry] = [
        "person": Entry(label: "Person", category: .person, typicalHeight: 1.7),
        "dog": Entry(label: "Dog", category: .obstacle, typicalHeight: 0.5),
        "cat": Entry(label: "Cat", category: .obstacle, typicalHeight: 0.3),
        "chair": Entry(label: "Chair", category: .furniture, typicalHeight: 0.9),
        "couch": Entry(label: "Couch", category: .furniture, typicalHeight: 0.85),
        "bench": Entry(label: "Bench", category: .furniture, typicalHeight: 0.8),
        "bed": Entry(label: "Bed", category: .furniture, typicalHeight: 0.6),
        "dining table": Entry(label: "Table", category: .furniture, typicalHeight: 0.75),
        "toilet": Entry(label: "Toilet", category: .furniture, typicalHeight: 0.75),
        "sink": Entry(label: "Sink", category: .furniture, typicalHeight: 0.9),
        "refrigerator": Entry(label: "Fridge", category: .furniture, typicalHeight: 1.7),
        "oven": Entry(label: "Oven", category: .furniture, typicalHeight: 0.9),
        "microwave": Entry(label: "Microwave", category: .furniture, typicalHeight: 0.3),
        "tv": Entry(label: "TV", category: .furniture, typicalHeight: 0.6),
        "potted plant": Entry(label: "Plant", category: .obstacle, typicalHeight: 0.8),
        "suitcase": Entry(label: "Suitcase", category: .obstacle, typicalHeight: 0.6),
        "backpack": Entry(label: "Bag", category: .obstacle, typicalHeight: 0.5),
        "handbag": Entry(label: "Bag", category: .obstacle, typicalHeight: 0.3),
        "bicycle": Entry(label: "Bike", category: .vehicle, typicalHeight: 1.0),
    ]

    static func entry(for identifier: String) -> Entry? {
        entries[identifier.lowercased()]
    }

    /// Every name the indoor camera can say, for pre-recording.
    static var labels: Set<String> { Set(entries.values.map(\.label)) }
}
