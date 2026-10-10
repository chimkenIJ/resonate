import ARKit
import CoreVideo
import Foundation
import simd

/// Reads an ARKit LiDAR depth map. Valid only inside `DepthReader.read(...)`, while the buffers are locked.
///
/// Coordinate notes: ARKit's camera image and depth map are landscape (sensor orientation). The app
/// shows them upright in portrait, which is the landscape image rotated 90° clockwise (orientation
/// `.right`). A point at portrait (px, py) is at landscape (lx, ly) = (py, 1 − px), all normalized.
nonisolated struct DepthReader {
    private let depth: UnsafePointer<Float32>
    private let depthRowStride: Int
    private let confidence: UnsafePointer<UInt8>?
    private let confidenceRowStride: Int
    let width: Int
    let height: Int
    /// Camera intrinsics scaled to depth-map pixels.
    private let fx: Float, fy: Float, cx: Float, cy: Float
    private let cameraTransform: simd_float4x4

    /// Nearest and farthest depth trusted (LiDAR is reliable to about 5 m).
    static let validRange: ClosedRange<Float> = 0.2...5.5

    static func read<T>(_ depthData: ARDepthData, camera: ARCamera, _ body: (DepthReader) -> T) -> T? {
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let confidenceMap = depthData.confidenceMap
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let scaleX = Float(width) / Float(camera.imageResolution.width)
        let scaleY = Float(height) / Float(camera.imageResolution.height)
        let k = camera.intrinsics

        let reader = DepthReader(
            depth: depthBase.assumingMemoryBound(to: Float32.self),
            depthRowStride: CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride,
            confidence: confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) },
            confidenceRowStride: confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0,
            width: width,
            height: height,
            fx: k[0][0] * scaleX, fy: k[1][1] * scaleY,
            cx: k[2][0] * scaleX, cy: k[2][1] * scaleY,
            cameraTransform: camera.transform
        )
        return body(reader)
    }

    /// Depth in meters at a depth-map pixel, or nil if low confidence or out of range.
    func depth(x: Int, y: Int) -> Float? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        if let confidence, confidence[y * confidenceRowStride + x] < UInt8(ARConfidenceLevel.medium.rawValue) { return nil }
        let value = depth[y * depthRowStride + x]
        return Self.validRange.contains(value) ? value : nil
    }

    /// Distance to the nearer part of what's inside a box (portrait, normalized, top-left origin).
    func distance(in box: CGRect) -> Double? {
        // Center 50% of the box, so edges and background around the object don't count.
        let inner = box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25)
        let minX = Int((inner.minY * Double(width)).rounded(.down))
        let maxX = Int((inner.maxY * Double(width)).rounded(.up))
        let minY = Int(((1 - inner.maxX) * Double(height)).rounded(.down))
        let maxY = Int(((1 - inner.minX) * Double(height)).rounded(.up))
        guard maxX > minX, maxY > minY else { return nil }

        let step = max(1, min(maxX - minX, maxY - minY) / 12)
        var values: [Double] = []
        for y in stride(from: minY, through: maxY, by: step) {
            for x in stride(from: minX, through: maxX, by: step) {
                if let d = depth(x: x, y: y) { values.append(Double(d)) }
            }
        }
        guard values.count >= 6 else { return nil }
        return TerrainAnalyzer.percentile(values, 0.25)
    }

    /// Depth samples in gravity-aligned walking coordinates, for TerrainAnalyzer.
    func terrainSamples(stride step: Int = 3) -> [TerrainSample] {
        let origin = simd_make_float3(cameraTransform.columns.3)
        let back = simd_make_float3(cameraTransform.columns.2)
        // Forward is where the camera looks (−Z), flattened onto the ground plane.
        var forward = simd_float3(-back.x, 0, -back.z)
        let flatLength = simd_length(forward)
        guard flatLength > 0.3 else { return [] } // pointing straight down or up: no sense of "ahead"
        forward /= flatLength
        let right = simd_cross(forward, simd_float3(0, 1, 0))

        var samples: [TerrainSample] = []
        samples.reserveCapacity((width / step) * (height / step))
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let d = depth(x: x, y: y) else { continue }
                // Unproject into camera space: +x right, +y up, looking down −z.
                let camera = simd_float4((Float(x) + 0.5 - cx) / fx * d, -(Float(y) + 0.5 - cy) / fy * d, -d, 1)
                let world = simd_make_float3(cameraTransform * camera) - origin
                samples.append(TerrainSample(
                    forward: Double(simd_dot(world, forward)),
                    lateral: Double(simd_dot(world, right)),
                    height: Double(world.y),
                    imageY: (Double(x) + 0.5) / Double(width)
                ))
            }
        }
        return samples
    }
}
