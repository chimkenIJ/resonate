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

/// One update from the indoor scanner: the room so far and where the user is in it.
/// IndoorComposer and IndoorNavigator decide what's worth saying.
nonisolated struct IndoorSnapshot: Sendable {
    /// Walls, doors, furniture, and stairs from the scan, plus people (tracked, so each is one element).
    var elements: [RoomElement]
    var pose: FloorPose
    /// Boxes for the camera view, with the same identifiers as `elements`.
    var objects: [DetectedObject]
    /// Scanning tip from RoomPlan ("Move the phone more slowly."), if any.
    var coaching: String? = nil
    /// Size of the upright camera image the boxes refer to (see DetectionFrame.imageSize).
    var imageSize: CGSize? = nil
}

nonisolated enum SceneSetting: String, Codable, Sendable {
    case outdoor, indoor
    /// Where the door is, whether it's open, and how to open it.
    case door
}

/// Result of the color recognition module.
nonisolated struct ColorReading: Hashable, Sendable {
    /// Specific name, for example "Navy blue".
    var name: String
    /// Basic family, for example "Blue".
    var family: String
    var hex: String
}
