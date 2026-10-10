import CoreGraphics
import Foundation

/// Shape on the mini top-down map in the indoor sheet. Coordinates are normalized (0...1).
nonisolated struct MiniMapItem: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var category: ObjectCategory
    var rect: CGRect
    /// Radians, around the rect's center (walls at an angle).
    var rotation: Double = 0
}

/// One update from the indoor scanner.
nonisolated struct IndoorSnapshot: Sendable {
    var objects: [DetectedObject]
    /// For example "Chair 2 steps ahead, on your right."
    var headline: String
    /// For example "Walk straight. Wall stays on your left. Door is open ahead."
    var guidance: String
    var guidanceIcon: Maneuver
    var miniMap: [MiniMapItem]
    /// Safety alert when something is very close in the walking path.
    var alert: ObstacleAlert? = nil
    /// Stable key for `headline`, so changing step counts aren't re-announced.
    var announcementKey: String = ""
    /// Scanning tip from RoomPlan ("Move the phone more slowly."), if any.
    var coaching: String? = nil
    /// Size of the upright camera image the boxes refer to (see DetectionFrame.imageSize).
    var imageSize: CGSize? = nil
}

nonisolated enum SceneSetting: String, Codable, Sendable {
    case outdoor, indoor
}

/// Result of the color recognition module.
nonisolated struct ColorReading: Hashable, Sendable {
    /// Specific name, for example "Navy blue".
    var name: String
    /// Basic family, for example "Blue".
    var family: String
    var hex: String
}
