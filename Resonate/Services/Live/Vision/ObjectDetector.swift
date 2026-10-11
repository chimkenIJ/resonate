import CoreML
import Foundation
import OSLog
import Vision

/// A YOLO detection in the upright camera image.
nonisolated struct RawDetection: Sendable {
    let identifier: String
    let confidence: Float
    /// Normalized, top-left origin, in the upright (portrait) image.
    let box: CGRect
}

/// Runs YOLO11s through Vision. Thread-safe; call from the frame-processing queue.
nonisolated final class ObjectDetector: @unchecked Sendable {
    private let model: VNCoreMLModel?

    init() {
        guard let url = Bundle.main.url(forResource: "YOLO11s", withExtension: "mlmodelc") else {
            Log.vision.error("YOLO11s.mlmodelc missing from the app bundle")
            model = nil
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all // Neural Engine when available
        do {
            model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
        } catch {
            Log.vision.error("Couldn't load YOLO11s: \(String(describing: error), privacy: .public)")
            model = nil
        }
    }

    /// Detections in `pixelBuffer`, which is displayed upright after applying `orientation`.
    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [RawDetection] {
        guard let model else { return [] }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
        } catch {
            return []
        }
        return (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation in
            guard let top = observation.labels.first, top.confidence >= ObjectCatalog.minimumConfidence(for: top.identifier)
            else { return nil }
            let box = observation.boundingBox // bottom-left origin
            return RawDetection(
                identifier: top.identifier,
                confidence: top.confidence,
                box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            )
        }
    }
}

/// Shared logic for turning detections into labeled, ranged objects.
nonisolated enum FrameAnalysis {
    /// Frames per second to analyze, lowered when the phone is getting hot. Fast enough for the tracker
    /// to confirm things within half a second; what's said is paced separately (WalkNarrator).
    static var analysisInterval: TimeInterval {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: 1.0 / 3
        case .serious: 1.0 / 5
        default: 1.0 / 10
        }
    }

    /// - Parameters:
    ///   - depth: LiDAR distance for a box, if available.
    ///   - focalLengthPixels: focal length of the upright image, for size-based estimates and sideways offsets.
    ///   - imageHeightPixels, imageWidthPixels: size of the upright image in pixels.
    ///   - world: ARKit world position of an image point at a distance, when available.
    static func objects(
        from detections: [RawDetection],
        depth: (CGRect) -> Double?,
        focalLengthPixels: Double,
        imageHeightPixels: Double,
        imageWidthPixels: Double,
        world: (CGPoint, Double) -> SIMD3<Double>? = { _, _ in nil }
    ) -> [DetectedObject] {
        detections.compactMap { detection in
            guard let entry = ObjectCatalog.entry(for: detection.identifier) else { return nil }
            let touchesEdge = detection.box.minY < 0.01 || detection.box.maxY > 0.99
            let boxHeightPixels = detection.box.height * imageHeightPixels
            let estimate = ObjectCatalog.estimatedDistance(
                typicalHeight: entry.typicalHeight,
                boxHeightPixels: boxHeightPixels,
                focalLengthPixels: focalLengthPixels,
                touchesEdge: touchesEdge
            )
            var distance = estimate
            if let measured = depth(detection.box) {
                if ObjectCatalog.sizeFits(typicalHeight: entry.typicalHeight, distance: measured, boxHeightPixels: boxHeightPixels,
                                          focalLengthPixels: focalLengthPixels, touchesEdge: touchesEdge) {
                    distance = measured
                } else if entry.category == .person || entry.category == .vehicle, measured < (estimate ?? 0) * 0.5 {
                    // LiDAR hit something in front of a far-away person or car: trust the size instead.
                    distance = estimate
                } else if entry.category == .person || entry.category == .vehicle {
                    // A "person" or "car" the wrong size for where it is: most likely not one.
                    return nil
                } else {
                    distance = measured
                }
            }
            let center = CGPoint(x: detection.box.midX, y: detection.box.midY)
            // Pinhole: sideways offset = pixels from center ÷ focal length × distance.
            let lateral = distance.map { Double(center.x - 0.5) * imageWidthPixels / focalLengthPixels * $0 }
            return DetectedObject(label: entry.label, category: entry.category, confidence: detection.confidence,
                                  boundingBox: detection.box, distanceMeters: distance, lateralMeters: lateral,
                                  worldPosition: distance.flatMap { world(center, $0) })
        }
    }

    /// Drops the generic depth "Obstacle" when YOLO already named something at about that distance
    /// in the walking path, so the user hears "Person ahead", not "Obstacle ahead" too.
    static func merge(labeled: [DetectedObject], terrain: [DetectedObject]) -> [DetectedObject] {
        let filtered = terrain.filter { item in
            guard item.label == "Obstacle", let d = item.distanceMeters else { return true }
            return !labeled.contains { object in
                guard let od = object.distanceMeters else { return false }
                return abs(od - d) < 0.8 && (0.25...0.75).contains(object.boundingBox.midX)
            }
        }
        return labeled + filtered
    }
}
