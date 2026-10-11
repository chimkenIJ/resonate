import ARKit
import Foundation
import OSLog
import RoomPlan
import simd

/// Indoor scanning with Apple RoomPlan (LiDAR): walls, doors (open or closed), doorways, furniture,
/// and stairs, in real time. On top of that, the camera recognizes what RoomPlan doesn't (people,
/// pets, plants, bags, the TV, and furniture before RoomPlan has mapped it; see IndoorCatalog), and
/// the depth sensor catches anything else in the way and single steps. All of it is measured with
/// LiDAR, grouped (a person with a bag), and tracked so each thing is recognized once and keeps its
/// name. Everything runs on the phone.
final class RoomScanService: IndoorScanServicing {
    static var isSupportedOnDevice: Bool { RoomCaptureSession.isSupported }

    /// Our own AR session, shared with RoomPlan, so the app can ask for LiDAR depth (RoomPlan's own session
    /// doesn't hand depth to the app, and without it nothing unnamed, like a pole or a cone, can be seen).
    private let arSession = ARSession()
    private lazy var captureSession = RoomCaptureSession(arSession: arSession)
    private var checkedDepth = false
    private let delegateProxy = RoomDelegateProxy()
    private let detector = ObjectDetector()
    private var elements: [RoomElement] = []
    private var coaching: String?
    private var loop: Task<Void, Never>?
    private var tracker = ObstacleTracker()
    /// The floor's height in world space, remembered so obstacles are still found while the phone is
    /// held level and the floor right in front is out of view.
    private var floorWorldY: Double?

    /// The camera's things that RoomPlan already found within this distance are dropped (no doubles).
    nonisolated private static let duplicateDistance = 0.6

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
            tracker = ObstacleTracker()
            floorWorldY = nil
            checkedDepth = false
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

    /// Indoors a small drop is a step, not a curb.
    nonisolated static let stepDown = "Step down"

    func latestFrameJPEG() async -> Data? {
        guard let frame = captureSession.arSession.currentFrame else { return nil }
        return FrameRelay.jpeg(from: frame.capturedImage)
    }

    // MARK: Snapshot

    /// Once scanning has started: if RoomPlan's configuration didn't turn on depth, turn it on, keeping
    /// tracking and the room so far.
    private func ensureDepth(_ frame: ARFrame) {
        guard !checkedDepth else { return }
        if frame.sceneDepth != nil || frame.smoothedSceneDepth != nil {
            checkedDepth = true
            Log.vision.notice("Room scan depth: available")
            return
        }
        // Wait until RoomPlan has set the session up, then add depth to its configuration.
        guard let running = arSession.configuration as? ARWorldTrackingConfiguration,
              let configuration = running.copy() as? ARWorldTrackingConfiguration else { return }
        checkedDepth = true
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        } else {
            return
        }
        Log.vision.notice("Room scan had no depth; turning it on")
        arSession.run(configuration)
    }

    private func makeSnapshot() async -> IndoorSnapshot? {
        guard let frame = captureSession.arSession.currentFrame else { return nil }
        ensureDepth(frame)
        let camera = frame.camera
        let transform = camera.transform
        let position = simd_make_float3(transform.columns.3)
        let back = simd_make_float3(transform.columns.2)
        var forward = SIMD2<Double>(Double(-back.x), Double(-back.z))
        let length = (forward * forward).sum().squareRoot()
        guard length > 0.3 else { return nil } // phone pointing at the floor or ceiling
        forward /= length
        let pose = FloorPose(position: SIMD2(Double(position.x), Double(position.z)), forward: forward)

        // The camera's objects and the depth sensor's obstacles and steps, measured with LiDAR, off the main thread.
        let resolution = camera.imageResolution
        let imageSize = CGSize(width: resolution.height, height: resolution.width)
        nonisolated(unsafe) let arFrame = frame
        let detector = detector
        let knownFloor = floorWorldY
        let (found, floor) = await Task.detached(priority: .userInitiated) { () -> ([DetectedObject], Double?) in
            let frame = arFrame
            let detections = detector.detect(in: frame.capturedImage, orientation: .right)
            let geometry = CameraGeometry(frame.camera)
            let walkingPose = geometry.pose
            func objects(depth: (CGRect) -> Double?) -> [DetectedObject] {
                FrameAnalysis.objects(from: detections, depth: depth, focalLengthPixels: geometry.focalLengthPixels,
                                      imageHeightPixels: Double(resolution.width), imageWidthPixels: geometry.uprightWidthPixels,
                                      world: { point, distance in walkingPose == nil ? nil : geometry.worldPoint(portrait: point, depth: distance) },
                                      // Real names indoors, and everything walking outside knows about too (posts, signs…).
                                      catalog: { IndoorCatalog.entry(for: $0) ?? ObjectCatalog.entry(for: $0) })
            }
            guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return (objects(depth: { _ in nil }), nil) }
            return DepthReader.read(depth, camera: frame.camera) { reader -> ([DetectedObject], Double?) in
                let seen = objects(depth: { reader.distance(in: $0) })
                let samples = reader.terrainSamples()
                let phoneY = walkingPose?.origin.y ?? 0

                // Steps up or down, and the same "something in the way" check walking outside uses.
                let findings = TerrainAnalyzer.analyze(samples)
                let steps = TerrainAnalyzer.objects(from: findings).map { item in
                    var item = item
                    if item.label == "Curb drop" { item.label = Self.stepDown }
                    if let walkingPose, let distance = item.distanceMeters { item.worldPosition = walkingPose.origin + walkingPose.forward * distance }
                    return item
                }

                // Anything standing on the floor, named or not. What the camera already named is skipped here.
                let measuredFloor = IndoorObstacles.floorLevel(samples)
                guard let floor = measuredFloor ?? knownFloor.map({ $0 - phoneY }) else { return (seen + steps, nil) }
                let things = IndoorObstacles.find(samples, floor: floor)
                let unknown = things.compactMap { thing -> DetectedObject? in
                    let world = walkingPose.map { $0.origin + $0.forward * thing.forward + $0.right * thing.lateral }
                    let named = seen.contains { object in
                        if let world, let other = object.worldPosition {
                            let gap = SIMD2(world.x - other.x, world.z - other.z)
                            return (gap * gap).sum().squareRoot() <= Self.duplicateDistance
                        }
                        return ObstacleTracker.iou(object.boundingBox, thing.box) >= 0.3
                    }
                    guard !named else { return nil }
                    return DetectedObject(label: ObstacleTracker.genericLabel, category: .obstacle, confidence: 1,
                                          boundingBox: thing.box, distanceMeters: thing.distance,
                                          lateralMeters: thing.lateral, worldPosition: world)
                }
                // The outdoor-style check found the same thing the obstacle finder or the camera did: say it once.
                let others = steps.filter { item in
                    guard item.label == ObstacleTracker.genericLabel, let distance = item.distanceMeters else { return true }
                    return !things.contains { abs($0.distance - distance) < 0.8 && abs($0.lateral) < 0.8 }
                        && !seen.contains { abs(($0.distanceMeters ?? 99) - distance) < 0.8 && (0.25...0.75).contains($0.boundingBox.midX) }
                }
                return (seen + others + unknown, measuredFloor.map { $0 + phoneY })
            } ?? ([], nil)
        }.value
        if let floor {
            // Smooth it: the floor doesn't move, the estimate wobbles a little.
            floorWorldY = floorWorldY.map { $0 * 0.8 + floor * 0.2 } ?? floor
        }

        // Recognized once, then followed, keeping the name it's been seen as most often.
        let tracks = tracker.update(with: DetectionFrame(objects: SceneGrouping.group(found), depthSource: .lidar,
                                                         pose: CameraGeometry(camera).pose), now: .now)
        let room = elements
        let confirmed = tracks.filter { $0.isConfirmed && ($0.isVisible || $0.worldPosition != nil) }
        var seenOnly: [TrackedObstacle] = []
        let extra = confirmed.compactMap { track -> RoomElement? in
            let center: SIMD2<Double>
            if let world = track.worldPosition {
                center = SIMD2(world.x, world.z)
            } else if let ahead = track.forward, let side = track.lateral {
                center = pose.position + pose.forward * ahead + pose.right * side
            } else {
                return nil
            }
            // Already in the room scan: RoomPlan's version has the real shape, so keep that one. Something
            // found only by depth is the room scan's when it sits inside a piece of furniture or against a wall
            // (it's part of that wall); a cone a little way from the wall is still its own obstacle.
            let fromDepth = track.label == ObstacleTracker.genericLabel || track.category == .stairs || track.category == .dropOff
            let duplicate = room.contains { element in
                let gap = IndoorComposer.distance(from: center, to: element)
                guard fromDepth else { return element.label == track.label && gap <= Self.duplicateDistance }
                return element.kind == .object ? gap <= 0.2 : gap <= 0.3
            }
            guard !duplicate else { return nil }
            seenOnly.append(track)
            let half = track.label == SceneGrouping.people ? 0.5 : (track.category == .furniture ? 0.35 : 0.25)
            return RoomElement(kind: .object, label: track.label, category: track.category, footprint: [
                center + SIMD2(-half, -half), center + SIMD2(half, -half),
                center + SIMD2(half, half), center + SIMD2(-half, half),
            ], id: track.id)
        }

        return IndoorSnapshot(
            elements: room + extra,
            pose: pose,
            objects: overlayBoxes(camera: camera, imageSize: imageSize, pose: pose) + seenOnly.filter(\.isVisible).map(\.object),
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
            return DetectedObject(id: element.id, label: element.label, category: element.category, confidence: 1,
                                  boundingBox: box, distanceMeters: max(placed.distance, 0.1))
        }
    }
}

// MARK: - RoomPlan → RoomElement

nonisolated extension RoomElement {
    static func from(_ room: CapturedRoom) -> [RoomElement] {
        var elements: [RoomElement] = []
        func add(_ kind: Kind, _ label: String, _ category: ObjectCategory, _ footprint: [SIMD2<Double>],
                 _ transform: simd_float4x4, _ dimensions: simd_float3, _ id: UUID) {
            elements.append(RoomElement(kind: kind, label: label, category: category, footprint: footprint,
                                        bottom: Double(transform.columns.3.y - dimensions.y / 2),
                                        height: Double(dimensions.y), id: id))
        }
        for wall in room.walls {
            add(.wall, "Wall", .wall, line(wall.transform, wall.dimensions), wall.transform, wall.dimensions, wall.identifier)
        }
        for door in room.doors {
            let isOpen: Bool
            if case .door(let open) = door.category { isOpen = open } else { isOpen = false }
            add(.door(isOpen: isOpen), "Door", .door, line(door.transform, door.dimensions), door.transform, door.dimensions, door.identifier)
        }
        for opening in room.openings {
            add(.opening, "Doorway", .door, line(opening.transform, opening.dimensions), opening.transform, opening.dimensions, opening.identifier)
        }
        for object in room.objects {
            let (label, category) = describe(object.category)
            add(.object, label, category, box(object.transform, object.dimensions), object.transform, object.dimensions, object.identifier)
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
