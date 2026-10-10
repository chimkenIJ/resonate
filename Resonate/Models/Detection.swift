import CoreGraphics
import Foundation

/// What kind of thing was detected. Drives the overlay color and alert wording.
nonisolated enum ObjectCategory: String, Codable, Hashable, Sendable {
    case obstacle, vehicle, person, sign, dropOff, stairs, wall, door, furniture

    var accent: Accent {
        switch self {
        case .obstacle, .vehicle, .furniture: .clay
        case .person: .rose
        case .sign: .mauve
        case .dropOff, .stairs: .sand
        case .wall: .slate
        case .door: .sage
        }
    }
}

/// Where something is relative to the direction the phone is facing.
nonisolated enum RelativeDirection: String, Codable, Hashable, Sendable {
    case left, slightlyLeft, ahead, slightlyRight, right

    var spoken: String {
        switch self {
        case .left: "on your left"
        case .slightlyLeft: "ahead, slightly left"
        case .ahead: "straight ahead"
        case .slightlyRight: "ahead, slightly right"
        case .right: "on your right"
        }
    }

    /// Maps the horizontal center of a normalized bounding box (0 = left edge, 1 = right edge).
    init(normalizedX x: CGFloat) {
        switch x {
        case ..<0.2: self = .left
        case ..<0.4: self = .slightlyLeft
        case ..<0.6: self = .ahead
        case ..<0.8: self = .slightlyRight
        default: self = .right
        }
    }
}

/// One object found in a camera frame.
nonisolated struct DetectedObject: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Short display name, for example "Bike".
    var label: String
    var category: ObjectCategory
    var confidence: Float
    /// Normalized box with a top-left origin (already converted from Vision's bottom-left origin).
    var boundingBox: CGRect
    /// Distance in meters, from LiDAR or the depth model. Nil when unknown.
    var distanceMeters: Double?

    var direction: RelativeDirection { RelativeDirection(normalizedX: boundingBox.midX) }

    /// "Bike · 2 m"
    var overlayText: String {
        guard let distanceMeters else { return label }
        return "\(label) · \(DistanceText.short(distanceMeters))"
    }
}

/// How the distances in a frame were measured.
nonisolated enum DepthSource: String, Codable, Hashable, Sendable {
    case lidar, estimated, unavailable
}

nonisolated struct DetectionFrame: Sendable {
    var objects: [DetectedObject]
    var depthSource: DepthSource
    var timestamp: Date = .now
    /// Size of the upright camera image the boxes refer to, so the overlay can match the
    /// aspect-fill camera preview. Nil for mock frames (boxes are drawn stretched).
    var imageSize: CGSize? = nil
}
