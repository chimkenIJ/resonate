import CoreVideo
import Foundation

/// Finds the pedestrian signal in a frame and reads its colors. Runs on the frame-processing queue.
nonisolated enum SignalReader {
    /// The biggest traffic light near the middle of the view, read for walk / don't walk.
    /// Nil when there's no signal in view.
    static func read(_ detections: [RawDetection], in buffer: CVPixelBuffer, uprightHeightPixels: Double) -> SignalReading? {
        let signals = detections.filter {
            $0.identifier == "traffic light"
                && (0.15...0.85).contains($0.box.midX)
                && $0.box.height * uprightHeightPixels >= 14
        }
        guard let signal = signals.max(by: { $0.box.width * $0.box.height < $1.box.width * $1.box.height }) else { return nil }
        return SignalClassifier.classify(samples(in: signal.box, of: buffer))
    }

    /// Up to about 30×30 color samples from the inner 80% of a box (upright, normalized, top-left origin).
    /// Handles BGRA (camera) and full-range YCbCr (ARKit).
    static func samples(in box: CGRect, of buffer: CVPixelBuffer) -> [(r: Double, g: Double, b: Double)] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isBGRA = format == kCVPixelFormatType_32BGRA
        let isYCbCr = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isBGRA || isYCbCr else { return [] }

        let width = isBGRA ? CVPixelBufferGetWidth(buffer) : CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = isBGRA ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, 0)
        // Upright (px, py) is landscape (py, 1 − px).
        let inner = box.insetBy(dx: box.width * 0.1, dy: box.height * 0.1)
        let minX = max(0, Int(inner.minY * Double(width))), maxX = min(width - 1, Int(inner.maxY * Double(width)))
        let minY = max(0, Int((1 - inner.maxX) * Double(height))), maxY = min(height - 1, Int((1 - inner.minX) * Double(height)))
        guard maxX > minX, maxY > minY else { return [] }
        let step = max(1, max(maxX - minX, maxY - minY) / 30)

        var result: [(r: Double, g: Double, b: Double)] = []
        if isBGRA {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in stride(from: minY, through: maxY, by: step) {
                for x in stride(from: minX, through: maxX, by: step) {
                    let o = y * rowBytes + x * 4
                    result.append((Double(pixels[o + 2]) / 255, Double(pixels[o + 1]) / 255, Double(pixels[o]) / 255))
                }
            }
        } else {
            guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return [] }
            let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
            let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
            for y in stride(from: minY, through: maxY, by: step) {
                for x in stride(from: minX, through: maxX, by: step) {
                    let l = Double(luma[y * lumaRow + x])
                    let c = (y / 2) * chromaRow + (x / 2) * 2
                    let cb = Double(chroma[c]) - 128, cr = Double(chroma[c + 1]) - 128
                    func clamp(_ v: Double) -> Double { min(max(v / 255, 0), 1) }
                    result.append((clamp(l + 1.402 * cr), clamp(l - 0.344136 * cb - 0.714136 * cr), clamp(l + 1.772 * cb)))
                }
            }
        }
        return result
    }
}
