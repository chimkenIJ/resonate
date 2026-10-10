import ARKit
import Foundation
import OSLog
import RoomPlan
import simd

/// Indoor scanning with Apple RoomPlan (LiDAR): walls, doors (open or closed), doorways, furniture,
/// and stairs, in real time. YOLO adds people and pets, which RoomPlan doesn't track.
/// Everything runs on the phone.
final class RoomScanService: IndoorScanServicing {
    static var isSupportedOnDevice: Bool { RoomCaptureSession.isSupported }

    private let captureSession = RoomCaptureSession()
    private let delegateProxy = RoomDelegateProxy()
    private let detector = ObjectDetector()
    private var elements: [RoomElement] = []
    private var coaching: String?
    private var loop: Task<Void, Never>?

    var isSupported: Bool { Self.isSupportedOnDevice }
    var previewSource: CameraPreviewSource { .ar(captureSession.arSession) }

    init() {
        captureSession.delegate = delegateProxy
        delegateProxy.onRoom = { [weak self] elements in self?.elements = elements }
        delegateProxy.onCoaching = { [weak self] text in self?.coaching = text }
    }

    func requestPermission() async -> Bool { await CameraAccess.request() }

    func snapshots() -> AsyncStream<IndoorSnapshot> {
        AsyncStream { continuation in
            guard isSupported else {
                continuation.finish()
                return
            }
            elements = []
            var configuration = RoomCaptureSession.Configuration()
            configuration.isCoachingEnabled = true
            captureSession.run(configuration: configuration)

            loop = Task { [weak self] in
                while !Task.isCancelled {
                    if let snapshot = await self?.makeSnapshot() { continuation.yield(snapshot) }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.stop() }
            }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        captureSession.stop()
    }

    func latestFrameJPEG() async -> Data? {
        guard let frame = captureSession.arSession.currentFrame else { return nil }
        return FrameRelay.jpeg(from: frame.capturedImage)
    }

    // MARK: Snapshot

    private func makeSnapshot() async -> IndoorSnapshot? {
        guard let frame = captureSession.arSession.currentFrame else { return nil }
        let camera = frame.camera
        let transform = camera.transform
        let position = simd_make_float3(transform.columns.3)
        let back = simd_make_float3(transform.columns.2)
        var forward = SIMD2<Double>(Double(-back.x), Double(-back.z))
        let length = (forward * forward).sum().squareRoot()
        guard length > 0.3 else { return nil } // phone pointing at the floor or ceiling
        forward /= length
        let pose = FloorPose(position: SIMD2(Double(position.x), Double(position.z)), forward: forward)

        // People and pets from YOLO, off the main thread.
        let resolution = camera.imageResolution
        let imageSize = CGSize(width: resolution.height, height: resolution.width)
        nonisolated(unsafe) let pixelBuffer = frame.capturedImage
        let detector = detector
        let focal = Double(camera.intrinsics[0][0])
        let people = await Task.detached(priority: .userInitiated) {
            FrameAnalysis.objects(from: detector.detect(in: pixelBuffer, orientation: .right).filter {
                ["person", "dog", "cat", "suitcase", "backpack", "potted plant"].contains($0.identifier)
            }, depth: { _ in nil }, focalLengthPixels: focal, imageHeightPixels: Double(resolution.width),
               imageWidthPixels: Double(resolution.height))
        }.value

        var all = elements
        all += people.compactMap { person -> RoomElement? in
            guard let distance = person.distanceMeters else { return nil }
            // Place it on the floor in front of the user along the box's direction.
            let angle = Double(person.boundingBox.midX - 0.5) * 1.1 // ~63° horizontal field of view in portrait
            let ahead = pose.forward * cos(angle) + pose.right * sin(angle)
            let center = pose.position + ahead * distance
            let half = 0.25
            return RoomElement(kind: .object, label: person.label, category: person.category, footprint: [
                center + SIMD2(-half, -half), center + SIMD2(half, -half),
                center + SIMD2(half, half), center + SIMD2(-half, half),
            ])
        }

        let result = IndoorComposer.compose(all, pose: pose)
        return IndoorSnapshot(
            objects: overlayBoxes(camera: camera, imageSize: imageSize, pose: pose) + people,
            headline: result.headline,
            guidance: result.guidance,
            guidanceIcon: result.guidanceIcon,
            miniMap: result.miniMap,
            alert: result.alert,
            announcementKey: result.announcementKey,
            coaching: coaching,
            imageSize: imageSize
        )
    }

    /// Projects room elements into the camera image for the labeled boxes ("Wall · 1 m").
    private func overlayBoxes(camera: ARCamera, imageSize: CGSize, pose: FloorPose) -> [DetectedObject] {
        let cameraFromWorld = camera.transform.inverse
        return elements.compactMap { element -> DetectedObject? in
            let placed = IndoorComposer.place(element, pose: pose)
            guard placed.distance <= 6, abs(placed.bearing) <= 60 else { return nil }
            let bottom = Float(element.bottom), top = Float(element.bottom + element.height)
            let corners = element.footprint.flatMap { p -> [simd_float3] in
                [simd_float3(Float(p.x), bottom, Float(p.y)), simd_float3(Float(p.x), top, Float(p.y))]
            }
            var points: [CGPoint] = []
            for corner in corners {
                let inCamera = cameraFromWorld * simd_float4(corner, 1)
                guard inCamera.z < -0.05 else { continue } // behind the phone
                let projected = camera.projectPoint(corner, orientation: .portrait, viewportSize: imageSize)
                points.append(CGPoint(x: projected.x / imageSize.width, y: projected.y / imageSize.height))
            }
            guard points.count >= 2 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull, box.width > 0.02, box.height > 0.02 else { return nil }
            return DetectedObject(label: element.label, category: element.category, confidence: 1,
                                  boundingBox: box, distanceMeters: max(placed.distance, 0.1))
        }
    }
}

// MARK: - RoomPlan → RoomElement

nonisolated extension RoomElement {
    static func from(_ room: CapturedRoom) -> [RoomElement] {
        var elements: [RoomElement] = []
        func add(_ kind: Kind, _ label: String, _ category: ObjectCategory, _ footprint: [SIMD2<Double>],
                 _ transform: simd_float4x4, _ dimensions: simd_float3) {
            elements.append(RoomElement(kind: kind, label: label, category: category, footprint: footprint,
                                        bottom: Double(transform.columns.3.y - dimensions.y / 2),
                                        height: Double(dimensions.y)))
        }
        for wall in room.walls {
            add(.wall, "Wall", .wall, line(wall.transform, wall.dimensions), wall.transform, wall.dimensions)
        }
        for door in room.doors {
            let isOpen: Bool
            if case .door(let open) = door.category { isOpen = open } else { isOpen = false }
            add(.door(isOpen: isOpen), "Door", .door, line(door.transform, door.dimensions), door.transform, door.dimensions)
        }
        for opening in room.openings {
            add(.opening, "Doorway", .door, line(opening.transform, opening.dimensions), opening.transform, opening.dimensions)
        }
        for object in room.objects {
            let (label, category) = describe(object.category)
            add(.object, label, category, box(object.transform, object.dimensions), object.transform, object.dimensions)
        }
        return elements
    }

    /// A wall or door: a line along its local X axis.
    private static func line(_ transform: simd_float4x4, _ dimensions: simd_float3) -> [SIMD2<Double>] {
        let center = transform.columns.3
        let along = transform.columns.0 * (dimensions.x / 2)
        return [SIMD2(Double(center.x - along.x), Double(center.z - along.z)),
                SIMD2(Double(center.x + along.x), Double(center.z + along.z))]
    }

    /// An object: its rectangle on the floor.
    private static func box(_ transform: simd_float4x4, _ dimensions: simd_float3) -> [SIMD2<Double>] {
        let center = transform.columns.3
        let x = transform.columns.0 * (dimensions.x / 2)
        let z = transform.columns.2 * (dimensions.z / 2)
        let corners: [SIMD4<Float>] = [center - x - z, center + x - z, center + x + z, center - x + z]
        return corners.map { SIMD2<Double>(Double($0.x), Double($0.z)) }
    }

    private static func describe(_ category: CapturedRoom.Object.Category) -> (String, ObjectCategory) {
        switch category {
        case .chair: ("Chair", .furniture)
        case .table: ("Table", .furniture)
        case .sofa: ("Couch", .furniture)
        case .bed: ("Bed", .furniture)
        case .storage: ("Cabinet", .furniture)
        case .refrigerator: ("Fridge", .furniture)
        case .stove: ("Stove", .furniture)
        case .oven: ("Oven", .furniture)
        case .sink: ("Sink", .furniture)
        case .dishwasher: ("Dishwasher", .furniture)
        case .washerDryer: ("Washer", .furniture)
        case .toilet: ("Toilet", .furniture)
        case .bathtub: ("Bathtub", .furniture)
        case .fireplace: ("Fireplace", .furniture)
        case .television: ("TV", .furniture)
        case .stairs: ("Stairs", .stairs)
        @unknown default: ("Object", .obstacle)
        }
    }
}

/// RoomPlan's delegate isn't main-actor bound; this converts its callbacks to plain values and hands
/// them to the main actor.
private nonisolated final class RoomDelegateProxy: RoomCaptureSessionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onRoom: (@MainActor ([RoomElement]) -> Void)?
    nonisolated(unsafe) var onCoaching: (@MainActor (String?) -> Void)?

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let elements = RoomElement.from(room)
        Task { @MainActor in self.onRoom?(elements) }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text: String? = switch instruction {
        case .moveCloseToWall: "Move a little closer to the wall."
        case .moveAwayFromWall: "Step back from the wall a little."
        case .slowDown: "Move the phone more slowly."
        case .turnOnLight: "It's too dark to scan. Turn on a light if you can."
        case .lowTexture: "Point the phone at walls and furniture, not blank surfaces."
        case .normal: nil
        @unknown default: nil
        }
        Task { @MainActor in self.onCoaching?(text) }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        if let error { Log.vision.error("Room scan ended: \(String(describing: error), privacy: .public)") }
    }
}
