import ARKit
import AVFoundation
import CoreImage
import Foundation
import os

// MARK: - Shared frame plumbing

/// Thread-safe hand-off from the camera queue to the app: the current frame handler and pending
/// "describe the scene" snapshot requests.
nonisolated final class FrameRelay: @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (DetectionFrame) -> Void)?
        var detecting = true
        var snapshotWaiters: [CheckedContinuation<Data?, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setHandler(_ handler: (@Sendable (DetectionFrame) -> Void)?) {
        state.withLock { $0.handler = handler }
        if handler == nil { finishSnapshots(with: nil) }
    }

    /// False while the camera only serves snapshots (scan the area): frames skip object detection.
    var isDetecting: Bool {
        get { state.withLock { $0.detecting } }
        set { state.withLock { $0.detecting = newValue } }
    }

    func emit(_ frame: DetectionFrame) {
        let handler = state.withLock { $0.handler }
        handler?(frame)
    }

    func requestSnapshot() async -> Data? {
        await withCheckedContinuation { continuation in
            state.withLock { $0.snapshotWaiters.append(continuation) }
        }
    }

    var wantsSnapshot: Bool { state.withLock { !$0.snapshotWaiters.isEmpty } }

    /// Encodes the upright image as a JPEG for pending snapshot requests.
    func fulfillSnapshots(from pixelBuffer: CVPixelBuffer) {
        guard wantsSnapshot else { return }
        finishSnapshots(with: Self.jpeg(from: pixelBuffer))
    }

    private static let context = CIContext()

    /// The camera image upright, at most 1024 px, as a JPEG (for scene descriptions).
    static func jpeg(from pixelBuffer: CVPixelBuffer) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
        )
    }

    private func finishSnapshots(with data: Data?) {
        let waiters = state.withLock { state -> [CheckedContinuation<Data?, Never>] in
            defer { state.snapshotWaiters = [] }
            return state.snapshotWaiters
        }
        waiters.forEach { $0.resume(returning: data) }
    }
}

enum CameraAccess {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

// MARK: - LiDAR phones (ARKit)

/// Processes ARKit frames on a background queue: YOLO for labels, LiDAR for distances,
/// and terrain analysis for curbs, drop-offs, steps, and unlabeled obstacles.
nonisolated final class LiDARFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.ishajain.Resonate.obstacles", qos: .userInitiated)
    let relay = FrameRelay()
    private let detector = ObjectDetector()
    private var lastProcessed = Date.distantPast // touched only on `queue`

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= FrameAnalysis.analysisInterval || relay.wantsSnapshot else { return }
        lastProcessed = now

        let pixelBuffer = frame.capturedImage
        guard relay.isDetecting else {
            relay.fulfillSnapshots(from: pixelBuffer)
            return
        }
        let resolution = frame.camera.imageResolution // landscape
        let detections = detector.detect(in: pixelBuffer, orientation: .right)
        let geometry = CameraGeometry(frame.camera)
        let pose = geometry.pose

        func objects(depth: (CGRect) -> Double?) -> [DetectedObject] {
            FrameAnalysis.objects(from: detections, depth: depth,
                                  focalLengthPixels: geometry.focalLengthPixels, // landscape x = upright vertical
                                  imageHeightPixels: Double(resolution.width),
                                  imageWidthPixels: geometry.uprightWidthPixels,
                                  world: { point, distance in pose == nil ? nil : geometry.worldPoint(portrait: point, depth: distance) })
        }

        var labeled: [DetectedObject] = []
        var terrain: [DetectedObject] = []
        var clearance: PathClearance?
        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        if let depthData {
            DepthReader.read(depthData, camera: frame.camera) { reader in
                labeled = objects(depth: { reader.distance(in: $0) })
                let samples = reader.terrainSamples()
                // Pinned to the ground ahead, so their distance keeps counting down as the user walks.
                terrain = TerrainAnalyzer.objects(from: TerrainAnalyzer.analyze(samples)).map { item in
                    var item = item
                    if let pose, let distance = item.distanceMeters { item.worldPosition = pose.origin + pose.forward * distance }
                    return item
                }
                clearance = TerrainAnalyzer.clearance(samples)
            }
        } else {
            labeled = objects(depth: { _ in nil })
        }

        relay.fulfillSnapshots(from: pixelBuffer)
        relay.emit(DetectionFrame(
            objects: FrameAnalysis.merge(labeled: labeled, terrain: terrain),
            depthSource: depthData == nil ? .estimated : .lidar,
            imageSize: CGSize(width: resolution.height, height: resolution.width),
            pose: pose,
            clearance: clearance,
            signal: SignalReader.read(detections, in: pixelBuffer, uprightHeightPixels: Double(resolution.width))
        ))
    }
}

final class LiDARObstacleDetectionService: ObstacleDetectionServicing {
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    let session = ARSession()
    private let processor = LiDARFrameProcessor()
    private var isRunning = false

    var depthSource: DepthSource { .lidar }
    var previewSource: CameraPreviewSource { .ar(session) }

    init() {
        session.delegateQueue = processor.queue
        session.delegate = processor
    }

    func requestPermission() async -> Bool { await CameraAccess.request() }

    func frames(detecting: Bool) -> AsyncStream<DetectionFrame> {
        AsyncStream { continuation in
            processor.relay.isDetecting = detecting
            processor.relay.setHandler { continuation.yield($0) }
            let configuration = ARWorldTrackingConfiguration()
            configuration.frameSemantics = [.smoothedSceneDepth]
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            isRunning = true
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.stop() }
            }
        }
    }

    private func stop() {
        processor.relay.setHandler(nil)
        session.pause()
        isRunning = false
    }

    func latestFrameJPEG() async -> Data? {
        guard isRunning else { return nil }
        return await processor.relay.requestSnapshot()
    }
}

// MARK: - Phones without LiDAR (camera only)

/// Camera frames → YOLO, with distance estimated from each object's typical size.
nonisolated final class CameraFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.ishajain.Resonate.camera", qos: .userInitiated)
    let relay = FrameRelay()
    private let detector = ObjectDetector()
    private var lastProcessed = Date.distantPast // touched only on `queue`
    /// Focal length in pixels along the upright image's vertical axis. Set before frames arrive.
    var focalLengthPixels: Double = 1400

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= FrameAnalysis.analysisInterval || relay.wantsSnapshot,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now
        guard relay.isDetecting else {
            relay.fulfillSnapshots(from: pixelBuffer)
            return
        }

        let landscapeWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let landscapeHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
        let detections = detector.detect(in: pixelBuffer, orientation: .right)
        let objects = FrameAnalysis.objects(
            from: detections,
            depth: { _ in nil },
            focalLengthPixels: focalLengthPixels,
            imageHeightPixels: landscapeWidth,
            imageWidthPixels: landscapeHeight
        )
        relay.fulfillSnapshots(from: pixelBuffer)
        relay.emit(DetectionFrame(objects: objects, depthSource: .estimated,
                                  imageSize: CGSize(width: landscapeHeight, height: landscapeWidth),
                                  signal: SignalReader.read(detections, in: pixelBuffer, uprightHeightPixels: landscapeWidth)))
    }
}

final class CameraObstacleDetectionService: ObstacleDetectionServicing {
    let session = AVCaptureSession()
    private let processor = CameraFrameProcessor()
    private var isConfigured = false
    private var isRunning = false

    var depthSource: DepthSource { .estimated }
    var previewSource: CameraPreviewSource { .capture(session) }

    func requestPermission() async -> Bool { await CameraAccess.request() }

    func frames(detecting: Bool) -> AsyncStream<DetectionFrame> {
        AsyncStream { continuation in
            processor.relay.isDetecting = detecting
            processor.relay.setHandler { continuation.yield($0) }
            configureIfNeeded()
            nonisolated(unsafe) let session = session
            processor.queue.async { session.startRunning() }
            isRunning = true
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.stop() }
            }
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: processor.queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // The horizontal field of view spans the 1280-pixel landscape width, which is the upright image's height.
        let fov = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        processor.focalLengthPixels = 640 / tan(fov / 2)
        isConfigured = true
    }

    private func stop() {
        processor.relay.setHandler(nil)
        nonisolated(unsafe) let session = session
        processor.queue.async { session.stopRunning() }
        isRunning = false
    }

    func latestFrameJPEG() async -> Data? {
        guard isRunning else { return nil }
        return await processor.relay.requestSnapshot()
    }
}
