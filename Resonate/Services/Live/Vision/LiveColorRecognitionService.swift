import AVFoundation
import Foundation

/// Samples the middle of the camera view a few times a second and names its color. On-device, offline.
nonisolated final class ColorFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.ishajain.Resonate.colors", qos: .userInitiated)
    /// Set from the main actor before frames start; read on `queue`.
    nonisolated(unsafe) var onReading: (@Sendable (ColorReading) -> Void)?

    private var lastSample = Date.distantPast
    private var candidate: String?
    private var candidateCount = 0
    private var lastEmitted: String?

    /// How often to sample, and how many matching samples in a row before speaking a new color
    /// (so a moving camera doesn't make it chatter).
    private let interval: TimeInterval = 0.2
    private let stableSamples = 3

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) >= interval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let color = Self.centerColor(of: buffer) else { return }
        lastSample = now

        let reading = ColorNamer.reading(red: color.r, green: color.g, blue: color.b)
        if reading.name == candidate {
            candidateCount += 1
        } else {
            candidate = reading.name
            candidateCount = 1
        }
        guard candidateCount >= stableSamples, reading.name != lastEmitted else { return }
        lastEmitted = reading.name
        onReading?(reading)
    }

    /// Median color of a small square in the middle of the frame (the aiming ring). The median ignores
    /// specks and glare better than an average.
    static func centerColor(of buffer: CVPixelBuffer) -> (r: Double, g: Double, b: Double)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let half = max(4, min(width, height) / 24)
        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        for y in stride(from: height / 2 - half, to: height / 2 + half, by: 2) {
            for x in stride(from: width / 2 - half, to: width / 2 + half, by: 2) {
                let offset = y * rowBytes + x * 4
                blues.append(pixels[offset])
                greens.append(pixels[offset + 1])
                reds.append(pixels[offset + 2])
            }
        }
        func median(_ values: [UInt8]) -> Double { Double(values.sorted()[values.count / 2]) / 255 }
        guard !reds.isEmpty else { return nil }
        return (median(reds), median(greens), median(blues))
    }
}

final class LiveColorRecognitionService: ColorRecognitionServicing {
    let session = AVCaptureSession()
    private let processor = ColorFrameProcessor()
    private var isConfigured = false

    var previewSource: CameraPreviewSource { .capture(session) }

    func requestPermission() async -> Bool { await CameraAccess.request() }

    func readings() -> AsyncStream<ColorReading> {
        AsyncStream { continuation in
            processor.onReading = { continuation.yield($0) }
            configureIfNeeded()
            nonisolated(unsafe) let session = session
            processor.queue.async { session.startRunning() }
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
        isConfigured = true
    }

    private func stop() {
        processor.onReading = nil
        nonisolated(unsafe) let session = session
        processor.queue.async { session.stopRunning() }
    }
}
