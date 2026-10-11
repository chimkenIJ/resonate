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

    /// From a bearing in degrees (0 = straight ahead, positive = right).
    init(bearingDegrees bearing: Double) {
        switch bearing {
        case ..<(-30): self = .left
        case ..<(-10): self = .slightlyLeft
        case ...10: self = .ahead
        case ...30: self = .slightlyRight
        default: self = .right
        }
    }

    /// Like `init(bearingDegrees:)`, but keeps `previous` until the bearing is clearly past the boundary,
    /// so something right on a boundary doesn't flip between "left" and "slightly left".
    static func stable(bearingDegrees bearing: Double, previous: RelativeDirection?, margin: Double = 4) -> RelativeDirection {
        let next = RelativeDirection(bearingDegrees: bearing)
        guard let previous, next != previous else { return next }
        let nearPrevious = RelativeDirection(bearingDegrees: bearing - margin) == previous
            || RelativeDirection(bearingDegrees: bearing + margin) == previous
        return nearPrevious ? previous : next
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
    /// Meters to the right of where the camera points (negative = left). Nil when the distance is unknown.
    var lateralMeters: Double? = nil
    /// Where it is in ARKit world space (LiDAR phones), so it can be followed as the user walks.
    var worldPosition: SIMD3<Double>? = nil

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

/// Where the user is and which way they face, flattened onto the ground (ARKit world space).
nonisolated struct WalkingPose: Hashable, Sendable {
    var origin: SIMD3<Double>
    /// Unit vectors on the ground plane.
    var forward: SIMD3<Double>
    var right: SIMD3<Double>

    /// Meters ahead and to the right of the user.
    func relative(_ point: SIMD3<Double>) -> (forward: Double, lateral: Double) {
        let offset = point - origin
        return ((offset * forward).sum(), (offset * right).sum())
    }
}

/// How far the user can walk before something blocks them, straight ahead and a step to each side.
/// Nil in a sector means nothing within range.
nonisolated struct PathClearance: Hashable, Sendable {
    var left: Double?
    var center: Double?
    var right: Double?
}

nonisolated struct DetectionFrame: Sendable {
    var objects: [DetectedObject]
    var depthSource: DepthSource
    var timestamp: Date = .now
    /// Size of the upright camera image the boxes refer to, so the overlay can match the
    /// aspect-fill camera preview. Nil for mock frames (boxes are drawn stretched).
    var imageSize: CGSize? = nil
    /// LiDAR phones only.
    var pose: WalkingPose? = nil
    var clearance: PathClearance? = nil
    /// The pedestrian signal in view, if any.
    var signal: SignalReading? = nil
}
